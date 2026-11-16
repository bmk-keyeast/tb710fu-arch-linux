// SPDX-License-Identifier: GPL-2.0-only
/* Userspace check of kbpack-codec.h against the daemon's captured frames (tb710fu-keyboard --selftest).
 *   cc -O2 -Wall -Werror -o codec-test codec-test.c && ./codec-test */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "kbpack-codec.h"

static int hex(const char *s, unsigned char *o)
{
	int n = 0;

	for (; s[0] && s[1]; s += 2)
		sscanf(s, "%2hhx", &o[n++]);
	return n;
}

static void unframe_eq(const char *frame, const char *plain)
{
	unsigned char f[64], p[64], want[64];
	int fn = hex(frame, f), pn = kbp_unframe(f, fn, p);

	if (!plain) {
		assert(pn < 0);
		return;
	}
	assert(pn == hex(plain, want) && !memcmp(p, want, pn));
}

int main(void)
{
	unsigned char f[64], p[32], q[64], want[64];
	int i, n, k;

	unframe_eq("ff4e11cac7a941512b", "16040402bb00");
	unframe_eq("ff4bd544e005cec3da", "6a0433020000");	/* stock TX */
	unframe_eq("ff4e11cac7a941512c", NULL);			/* bad checksum */
	unframe_eq("ff0fdfcbabfa516218bd847d5d44", "11080000000000000000");	/* sum over escapes */

	hex("6a0433020000", p);
	n = kbp_frame(p, 6, 0x4b, f);
	assert(n == hex("7e7eff4bd544e005cec3da7e", want) && !memcmp(f, want, n));	/* = stock */

	srand(1);
	for (i = 0; i < 500; i++) {
		static const unsigned char pick[] = { 0x7d, 0x7e, 0x00, 0xff };

		for (k = 0; k < 12; k++)
			p[k] = rand() % 5 < 4 ? pick[rand() % 4] : rand();
		n = kbp_frame(p, 12, rand() & 0x7f, f);
		assert(f[0] == 0x7e && f[1] == 0x7e && f[2] == 0xff && f[n - 1] == 0x7e);
		assert(!memchr(f + 3, 0x7e, n - 4));
		assert(kbp_unframe(f + 2, n - 3, q) == 12 && !memcmp(q, p, 12));
	}
	puts("codec-test ok");
	return 0;
}
