/*
 * noisestat: NV12 frames on stdin -> noise statistics on stdout. Nothing is
 * written anywhere; frames live only in memory.
 *   noisestat W H SKIP
 * Temporal: per-pixel std-dev of luma (and U, V) across the frames after SKIP,
 * averaged per 16x16 block; reports block percentiles (p10 = static/flat
 * regions, p50 = typical). Spatial: |Y - mean3x3(Y)| per block on the last
 * frame; p10 block ~ the noise floor in flat areas.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}

static int cmpd(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y;
}

static double pct(double *v, int n, double p)
{
	qsort(v, n, sizeof(*v), cmpd);
	return v[(int)(p * (n - 1))];
}

int main(int argc, char **argv)
{
	int w = atoi(argv[1]), h = atoi(argv[2]), skip = atoi(argv[3]);
	size_t ys = (size_t)w * h, fs = ys * 3 / 2, cs = ys / 4;
	unsigned char *f = malloc(fs);
	double *s = calloc(ys, 8), *q = calloc(ys, 8);
	double *cu = calloc(cs, 8), *cuq = calloc(cs, 8), *cv = calloc(cs, 8), *cvq = calloc(cs, 8);
	int n = 0, tot = 0;
	double t_first = 0, t_last = 0;
	unsigned char *prev = malloc(ys);
	double *dhp = malloc(ys * 8), hpsum = 0, gm[4096], rowvar = 0;
	int nd = 0, ng = 0;
	double *rs = calloc(h, 8), *rq = calloc(h, 8);
	double meany = 0, meanu = 0, meanv = 0;

	while (fread(f, 1, fs, stdin) == fs) {
		if (tot++ < skip)
			continue;
		if (!n) t_first = now(); t_last = now();
		n++;
		double m = 0, mu = 0, mv = 0;
		for (size_t i = 0; i < ys; i++) {
			double y = f[i];
			s[i] += y;
			q[i] += y * y;
			m += y;
		}
		for (size_t i = 0; i < cs; i++) {
			double u = f[ys + 2 * i], v = f[ys + 2 * i + 1];
			cu[i] += u; cuq[i] += u * u; cv[i] += v; cvq[i] += v * v;
			mu += u; mv += v;
		}
		meany += m / ys; meanu += mu / cs; meanv += mv / cs;
		if (ng < 4096) gm[ng++] = m / ys;
		for (int y = 0; y < h; y++) {
			double r = 0;
			for (int x = 0; x < w; x++) r += f[(size_t)y * w + x];
			r /= w; rs[y] += r; rq[y] += r * r;
		}
		/* high-passed frame difference: pixel noise without motion/banding */
		if (n > 1) {
			int k = 0;
			for (int y = 1; y < h - 1; y += 2)
				for (int x = 1; x < w - 1; x += 2) {
					double a = 0, c = 0;
					for (int dy = -1; dy <= 1; dy++)
						for (int dx = -1; dx <= 1; dx++) {
							size_t j = (size_t)(y + dy) * w + x + dx;
							double d = (double)f[j] - prev[j];
							a += d;
							if (!dy && !dx) c = d;
						}
					dhp[k++] = fabs(c - a / 9);
				}
			hpsum += pct(dhp, k, .5) * 1.4826 / sqrt(2 * (1 - 1.0 / 9));
			nd++;
		}
		memcpy(prev, f, ys);
	}
	if (n < 2) {
		fprintf(stderr, "only %d frames\n", n);
		return 1;
	}
	int bw = w / 16, bh = h / 16, nb = bw * bh;
	double *bt = calloc(nb, 8), *bsp = calloc(nb, 8), *bl = calloc(nb, 8);
	for (int by = 0; by < bh; by++)
		for (int bx = 0; bx < bw; bx++) {
			double t = 0, sp = 0, l = 0;
			for (int y = by * 16; y < by * 16 + 16; y++)
				for (int x = bx * 16; x < bx * 16 + 16; x++) {
					size_t i = (size_t)y * w + x;
					double mu = s[i] / n, var = q[i] / n - mu * mu;
					t += sqrt(var > 0 ? var * n / (n - 1) : 0);
					l += mu;
					if (x > 0 && y > 0 && x < w - 1 && y < h - 1) {
						double a = 0;
						for (int dy = -1; dy <= 1; dy++)
							for (int dx = -1; dx <= 1; dx++)
								a += f[i + dy * w + dx];
						sp += fabs(f[i] - a / 9);
					}
				}
			bt[by * bw + bx] = t / 256;
			bsp[by * bw + bx] = sp / 256;
			bl[by * bw + bx] = l / 256;
		}
	/* temporal noise in mid-tone blocks (luma 40..200) only */
	double *mid = calloc(nb, 8);
	int nm = 0;
	for (int i = 0; i < nb; i++)
		if (bl[i] > 40 && bl[i] < 200)
			mid[nm++] = bt[i];
	double ut = 0, vt = 0;
	for (size_t i = 0; i < cs; i++) {
		double a = cu[i] / n, b = cv[i] / n;
		ut += sqrt(fmax(cuq[i] / n - a * a, 0) * n / (n - 1));
		vt += sqrt(fmax(cvq[i] / n - b * b, 0) * n / (n - 1));
	}
	double gs = 0, gq = 0;
	for (int i = 0; i < ng; i++) { gs += gm[i]; gq += gm[i] * gm[i]; }
	for (int y = 0; y < h; y++) { double a = rs[y] / n; rowvar += rq[y] / n - a * a - 0; }
	printf("pixnoise(HP frame-diff, MAD sigma)=%.2f  globalY std=%.2f  rowmean temporal std(avg)=%.2f\n",
	       nd ? hpsum / nd : 0, sqrt(fmax(gq / ng - (gs / ng) * (gs / ng), 0)), sqrt(fmax(rowvar / h, 0)));
	printf("fps(after skip)=%.2f\n", (n - 1) / (t_last - t_first));
	printf("frames=%d meanY=%.1f meanU=%.1f meanV=%.1f\n", n, meany / n, meanu / n, meanv / n);
	printf("tempY p10=%.2f p25=%.2f p50=%.2f | midtone(n=%d) p10=%.2f p50=%.2f\n",
	       pct(bt, nb, .10), pct(bt, nb, .25), pct(bt, nb, .50), nm,
	       nm ? pct(mid, nm, .10) : 0, nm ? pct(mid, nm, .50) : 0);
	printf("tempUV meanU=%.2f meanV=%.2f\n", ut / cs, vt / cs);
	printf("spatY p10=%.2f p25=%.2f p50=%.2f\n", pct(bsp, nb, .10), pct(bsp, nb, .25), pct(bsp, nb, .50));
	return 0;
}
