// SPDX-License-Identifier: MIT
/*
 * m5pro-1p-seal: the root half of m5pro-1p-touchid. Keeps one secret per user
 * (the 1Password account password) sealed to this Mac's Secure Enclave.
 *
 *   pkexec m5pro-1p-seal seal     read the secret on stdin, seal it, store the record
 *   pkexec m5pro-1p-seal unseal   print the caller's secret to stdout (a pipe, never a terminal)
 *   pkexec m5pro-1p-seal forget   destroy the caller's record
 *          m5pro-1p-seal check    (root) exit 0 when SEP sealing works here
 *
 * Sealing is aurora-sep-userspace's (luks/sep-seal.c, vendored): a fresh
 * 32-byte AES key from the kernel "trusted" key type with the apple_sep
 * source, which only this Mac's SEP (with this Linux identity and key store)
 * can unseal, used by keyring serial through AF_ALG AES-256-CCM, so the AES
 * key never reaches userspace. The secret is padded to a fixed 256 bytes (its
 * length is not stored in the clear). The additional data binds a record to
 * this tool, the user and the record id, so a LUKS or SSH record of the same
 * SEP can never stand in for it.
 *
 * Only pkexec runs it (PKEXEC_UID names the user). polkit's
 * org.m5pro.1p-touchid.* actions decide who may: auth_self every time, so
 * the Omarchy dialog asks for Touch ID (pam_fprintd in /etc/pam.d/polkit-1)
 * or the login password. Records live in /var/lib/m5pro-1p-touchid/<uid>.record,
 * root-only. Unsealing is rate-limited per user.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/file.h>
#include <sys/random.h>
#include <sys/stat.h>

#include "sep-seal.h"

#define RECORD_MAGIC	"m5pro-1p-touchid 1"
#define STATE_DIR	"/var/lib/m5pro-1p-touchid"
#define RUN_DIR		"/run/m5pro-1p-touchid"
#define PAD_BYTES	256
#define SECRET_MAX	(PAD_BYTES - 2)
#define ID_BYTES	16
#define AAD_MAX		96
#define RECORD_MAX	(16 * 1024)
#define WAIT_S		10
/* At most this many unseals per user in RATE_WINDOW_S seconds. */
#define RATE_MAX	4
#define RATE_WINDOW_S	60

static void usage(void)
{
	fprintf(stderr, "usage: pkexec m5pro-1p-seal seal|unseal|forget, or (root) m5pro-1p-seal check\n");
}

static const char *explain(int r)
{
	switch (r) {
	case -ENODEV:
	case -ENOENT:
		return "no SEP trusted-key source (is apple_sep loaded with its key store?)";
	case -EBADMSG:
	case -EINVAL:
	case -EKEYREJECTED:
	case -EIO:
		return "refused: sealed on another Mac or Linux install, or the record was changed";
	case -EPERM:
	case -EACCES:
		return "needs root through pkexec";
	case -EAGAIN:
		return "too many unlocks in a minute; wait and try again";
	case -ENOKEY:
		return "nothing is set up for this user (run: m5pro-1p-touchid setup)";
	default:
		return strerror(-r);
	}
}

/* The invoking user, from pkexec. */
static int caller_uid(uid_t *uid)
{
	const char *s = getenv("PKEXEC_UID");
	char *end;
	unsigned long v;

	if (geteuid() != 0)
		return -EPERM;
	if (!s || !*s)
		return -EPERM;
	errno = 0;
	v = strtoul(s, &end, 10);
	if (errno || *end || v == 0 || v > INT_MAX)
		return -EPERM;
	*uid = (uid_t)v;
	return 0;
}

static void record_path(uid_t uid, char *out, size_t n)
{
	snprintf(out, n, STATE_DIR "/%u.record", (unsigned)uid);
}

static int record_aad(uid_t uid, const char *id_hex, char *aad, size_t n)
{
	int r = snprintf(aad, n, "m5pro-1p-touchid:1:%u:%s", (unsigned)uid, id_hex);

	return (r < 0 || (size_t)r >= n) ? -ENOBUFS : 0;
}

static int read_all(int fd, uint8_t *buf, size_t max, size_t *len)
{
	size_t got = 0;

	for (;;) {
		ssize_t n;

		if (got == max)
			return -EMSGSIZE;
		n = read(fd, buf + got, max - got);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -errno;
		}
		if (n == 0)
			break;
		got += (size_t)n;
	}
	*len = got;
	return 0;
}

static int write_all(int fd, const void *p, size_t n)
{
	const uint8_t *b = p;

	while (n) {
		ssize_t w = write(fd, b, n);

		if (w < 0) {
			if (errno == EINTR)
				continue;
			return -errno;
		}
		b += w;
		n -= (size_t)w;
	}
	return 0;
}

static int cmd_seal(void)
{
	uint8_t in[SECRET_MAX + 2], pad[PAD_BYTES], check[PAD_BYTES + SEP_SEAL_TAG_BYTES];
	uint8_t ct[PAD_BYTES + SEP_SEAL_TAG_BYTES], iv[SEP_SEAL_IV_BYTES], id[ID_BYTES];
	char id_hex[2 * ID_BYTES + 1], iv_hex[2 * SEP_SEAL_IV_BYTES + 1];
	char ct_hex[2 * sizeof(ct) + 1], aad[AAD_MAX], path[PATH_MAX], tmp[PATH_MAX] = "";
	char *blob = NULL;
	size_t len = 0, ct_len = 0, check_len = 0;
	int32_t k = 0, k2 = 0;
	uid_t uid;
	FILE *f = NULL;
	int fd = -1, r;

	r = caller_uid(&uid);
	if (r < 0)
		return r;
	if (isatty(STDIN_FILENO)) {
		fprintf(stderr, "m5pro-1p-seal: the secret comes on stdin from m5pro-1p-touchid setup, not a terminal\n");
		return -EPERM;
	}
	r = read_all(STDIN_FILENO, in, sizeof(in), &len);
	if (r < 0)
		goto out;
	/* One trailing newline is the caller's terminator, not the secret. */
	if (len && in[len - 1] == '\n')
		len--;
	if (len == 0 || len > SECRET_MAX) {
		r = -EINVAL;
		goto out;
	}
	if (getrandom(pad, sizeof(pad), 0) != sizeof(pad) ||
	    getrandom(iv, sizeof(iv), 0) != sizeof(iv) ||
	    getrandom(id, sizeof(id), 0) != sizeof(id)) {
		r = -EIO;
		goto out;
	}
	pad[0] = (uint8_t)(len & 0xff);
	pad[1] = (uint8_t)(len >> 8);
	memcpy(pad + 2, in, len);
	sep_hex_encode(id, sizeof(id), id_hex, sizeof(id_hex));
	r = record_aad(uid, id_hex, aad, sizeof(aad));
	if (r < 0)
		goto out;

	r = sep_key_new(&k, &blob);
	if (r < 0)
		goto out;
	r = sep_aead(k, 1, iv, (const uint8_t *)aad, strlen(aad), pad, sizeof(pad),
		     ct, sizeof(ct), &ct_len);
	sep_key_drop(k);
	if (r < 0)
		goto out;
	/* Prove the stored form opens, with a key loaded afresh from the blob. */
	r = sep_key_load(blob, 0, &k2);
	if (r < 0)
		goto out;
	r = sep_aead(k2, 0, iv, (const uint8_t *)aad, strlen(aad), ct, ct_len,
		     check, sizeof(check), &check_len);
	sep_key_drop(k2);
	if (r < 0)
		goto out;
	if (check_len != sizeof(pad) || memcmp(check, pad, sizeof(pad))) {
		r = -EIO;
		goto out;
	}

	sep_hex_encode(iv, sizeof(iv), iv_hex, sizeof(iv_hex));
	sep_hex_encode(ct, ct_len, ct_hex, sizeof(ct_hex));
	if (mkdir(STATE_DIR, 0755) < 0 && errno != EEXIST) {
		r = -errno;
		goto out;
	}
	/* Readable directory, root-only records: the user's tool can see that one exists. */
	(void)chmod(STATE_DIR, 0755);
	record_path(uid, path, sizeof(path));
	if (snprintf(tmp, sizeof(tmp), "%s.new", path) >= (int)sizeof(tmp)) {
		r = -ENAMETOOLONG;
		tmp[0] = '\0';
		goto out;
	}
	(void)unlink(tmp);
	fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (fd < 0) {
		r = -errno;
		goto out;
	}
	f = fdopen(fd, "w");
	if (!f) {
		r = -errno;
		goto out;
	}
	fd = -1;
	if (fprintf(f, "%s\nuid %u\nid %s\nblob %s\niv %s\nct %s\n", RECORD_MAGIC,
		    (unsigned)uid, id_hex, blob, iv_hex, ct_hex) < 0 ||
	    fflush(f) || fsync(fileno(f))) {
		r = -EIO;
		goto out;
	}
	if (fclose(f)) {
		f = NULL;
		r = -EIO;
		goto out;
	}
	f = NULL;
	if (rename(tmp, path) < 0) {
		r = -errno;
		goto out;
	}
	r = 0;
out:
	if (f)
		fclose(f);
	if (fd >= 0)
		close(fd);
	if (r < 0 && tmp[0])
		(void)unlink(tmp);
	sep_wipe(in, sizeof(in));
	sep_wipe(pad, sizeof(pad));
	sep_wipe(check, sizeof(check));
	free(blob);
	return r;
}

static int rate_limit(uid_t uid)
{
	char path[PATH_MAX];
	long stamps[RATE_MAX] = { 0 };
	time_t now = time(NULL);
	int fd, n = 0, r = 0, i;
	FILE *f;

	if (mkdir(RUN_DIR, 0700) < 0 && errno != EEXIST)
		return -errno;
	snprintf(path, sizeof(path), RUN_DIR "/%u.rate", (unsigned)uid);
	fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (fd < 0)
		return -errno;
	if (flock(fd, LOCK_EX) < 0) {
		close(fd);
		return -errno;
	}
	f = fdopen(fd, "r+");
	if (!f) {
		close(fd);
		return -errno;
	}
	while (n < RATE_MAX && fscanf(f, "%ld", &stamps[n]) == 1)
		if (now - stamps[n] < RATE_WINDOW_S)
			n++;
	if (n >= RATE_MAX) {
		r = -EAGAIN;
	} else {
		stamps[n++] = (long)now;
		rewind(f);
		if (ftruncate(fileno(f), 0) < 0)
			r = -errno;
		for (i = 0; i < n && !r; i++)
			fprintf(f, "%ld\n", stamps[i]);
	}
	fclose(f);
	return r;
}

static int load_record(uid_t uid, char *buf, char **id, struct sep_sealed *s)
{
	char path[PATH_MAX], *line, *save = NULL, *blob = NULL, *iv = NULL, *ct = NULL;
	const size_t ct_hex = 2 * (PAD_BYTES + SEP_SEAL_TAG_BYTES);
	size_t len = 0;
	unsigned long ruid = ULONG_MAX;
	int fd, r, first = 1;

	*id = NULL;
	memset(s, 0, sizeof(*s));
	record_path(uid, path, sizeof(path));
	fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0)
		return errno == ENOENT ? -ENOKEY : -errno;
	r = read_all(fd, (uint8_t *)buf, RECORD_MAX, &len);
	close(fd);
	if (r < 0)
		return r;
	buf[len] = '\0';
	for (line = strtok_r(buf, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
		char *sp;

		if (first) {
			if (strcmp(line, RECORD_MAGIC))
				return -EPROTONOSUPPORT;
			first = 0;
			continue;
		}
		sp = strchr(line, ' ');
		if (!sp)
			return -EINVAL;
		*sp++ = '\0';
		if (!strcmp(line, "uid"))
			ruid = strtoul(sp, NULL, 10);
		else if (!strcmp(line, "id"))
			*id = sp;
		else if (!strcmp(line, "blob"))
			blob = sp;
		else if (!strcmp(line, "iv"))
			iv = sp;
		else if (!strcmp(line, "ct"))
			ct = sp;
	}
	if (ruid != (unsigned long)uid || !*id || strlen(*id) != 2 * ID_BYTES || !blob ||
	    strlen(blob) > SEP_SEAL_BLOB_HEX_MAX || !iv || !ct || strlen(ct) != ct_hex)
		return -EINVAL;
	if (sep_hex_decode(iv, s->iv, sizeof(s->iv)) != SEP_SEAL_IV_BYTES)
		return -EINVAL;
	s->ct_len = ct_hex / 2;
	s->ct = malloc(s->ct_len);
	s->blob_hex = strdup(blob);
	if (!s->ct || !s->blob_hex)
		return -ENOMEM;
	if (sep_hex_decode(ct, s->ct, s->ct_len) != (long)s->ct_len)
		return -EINVAL;
	return 0;
}

static int cmd_unseal(void)
{
	uint8_t pad[PAD_BYTES + SEP_SEAL_TAG_BYTES];
	char *buf = NULL, *id, aad[AAD_MAX];
	struct sep_sealed s = { 0 };
	size_t out_len = 0, len;
	int32_t k = 0;
	uid_t uid;
	int r;

	r = caller_uid(&uid);
	if (r < 0)
		return r;
	if (isatty(STDOUT_FILENO)) {
		fprintf(stderr, "m5pro-1p-seal: refusing to print a secret to a terminal\n");
		return -EPERM;
	}
	r = rate_limit(uid);
	if (r < 0)
		return r;
	buf = calloc(1, RECORD_MAX + 1);
	if (!buf)
		return -ENOMEM;
	r = load_record(uid, buf, &id, &s);
	if (r < 0)
		goto out;
	r = record_aad(uid, id, aad, sizeof(aad));
	if (r < 0)
		goto out;
	r = sep_key_load(s.blob_hex, WAIT_S, &k);
	if (r < 0)
		goto out;
	r = sep_aead(k, 0, s.iv, (const uint8_t *)aad, strlen(aad), s.ct, s.ct_len,
		     pad, sizeof(pad), &out_len);
	sep_key_drop(k);
	if (r < 0)
		goto out;
	len = (size_t)pad[0] | ((size_t)pad[1] << 8);
	if (out_len != PAD_BYTES || len == 0 || len > SECRET_MAX) {
		r = -EIO;
		goto out;
	}
	r = write_all(STDOUT_FILENO, pad + 2, len);
out:
	sep_wipe(pad, sizeof(pad));
	sep_sealed_free(&s);
	if (buf) {
		sep_wipe(buf, RECORD_MAX + 1);
		free(buf);
	}
	return r;
}

static int cmd_forget(void)
{
	char path[PATH_MAX];
	uint8_t zero[4096] = { 0 };
	struct stat st;
	uid_t uid;
	int fd, r;

	r = caller_uid(&uid);
	if (r < 0)
		return r;
	record_path(uid, path, sizeof(path));
	fd = open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0)
		return errno == ENOENT ? 0 : -errno;
	/* Overwrite before unlinking; the blob alone is useless off this SEP anyway. */
	if (fstat(fd, &st) == 0) {
		off_t left = st.st_size;

		while (left > 0) {
			size_t n = left > (off_t)sizeof(zero) ? sizeof(zero) : (size_t)left;

			if (write_all(fd, zero, n) < 0)
				break;
			left -= (off_t)n;
		}
		(void)fsync(fd);
	}
	close(fd);
	if (unlink(path) < 0)
		return -errno;
	return 0;
}

static int cmd_check(void)
{
	static const uint8_t probe[SEP_SEAL_SECRET_BYTES] = { 1 };
	struct sep_sealed s;
	int r;

	if (geteuid() != 0)
		return -EPERM;
	r = sep_seal_secret("m5pro-1p-touchid:1:check", probe, sizeof(probe), &s);
	if (r == 0)
		sep_sealed_free(&s);
	return r;
}

int main(int argc, char **argv)
{
	int r;

	if (argc != 2) {
		usage();
		return 2;
	}
	umask(077);
	if (!strcmp(argv[1], "seal"))
		r = cmd_seal();
	else if (!strcmp(argv[1], "unseal"))
		r = cmd_unseal();
	else if (!strcmp(argv[1], "forget"))
		r = cmd_forget();
	else if (!strcmp(argv[1], "check"))
		r = cmd_check();
	else {
		usage();
		return 2;
	}
	if (r < 0) {
		fprintf(stderr, "m5pro-1p-seal %s: %s (%d)\n", argv[1], explain(r), r);
		return r == -ENOKEY ? 3 : (r == -EAGAIN ? 4 : 1);
	}
	return 0;
}
