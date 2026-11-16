/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Lenovo Keyboard Pack UART framing (docs/keyboard.md), shared by the driver and codec-test.c:
 *   7E FF esc(seed scrambled[0..n-1] sum8) 7E      keyboard -> host
 *   7E 7E FF esc(seed scrambled[0..n-1] sum8) 7E   host -> keyboard
 * esc: 7D -> 7D 5D, 7E -> 7D 5E. sum8 covers the escaped (wire) bytes of seed + payload.
 * plain[i] = scrambled[i] ^ kbp_key[(seed + i) & 0x3f]
 */
#ifndef KBPACK_CODEC_H
#define KBPACK_CODEC_H

static const unsigned char kbp_key[64] = {
	0xb8, 0x02, 0xd9, 0x57, 0xc6, 0x48, 0xc2, 0x13, 0xd7, 0xa6, 0x30, 0xbf, 0x40, 0xd3, 0x07, 0xce,
	0xc3, 0xab, 0xfa, 0x51, 0x62, 0x18, 0xbd, 0x84, 0x7d, 0xca, 0xe0, 0xcf, 0xf2, 0xac, 0xbc, 0x12,
	0xf5, 0x14, 0xd0, 0x72, 0xdc, 0x1a, 0x50, 0x00, 0x00, 0x32, 0xd1, 0x7b, 0x33, 0xb6, 0x10, 0xdd,
	0x6a, 0x21, 0xeb, 0x7e, 0x52, 0x5b, 0x3d, 0x9f, 0x85, 0xcb, 0x1f, 0x66, 0x73, 0x96, 0xa1, 0x60,
};

/*
 * Bytes between two 7E (the 7Es excluded) -> plain packet in out[], or -1 (not a frame, bad
 * checksum, too long). out must hold len bytes.
 */
static inline int kbp_unframe(const unsigned char *c, int len, unsigned char *out)
{
	unsigned int wire = 0, prev_wire = 0, last = 0;
	int i = 1, ntok = 0, seed = 0;

	if (len < 4 || c[0] != 0xff)
		return -1;
	while (i < len) {
		int v, w;

		if (c[i] == 0x7d) {
			int n = i + 1 < len ? c[i + 1] : 0;

			v = n ^ 0x20;
			w = 0x7d + n;
			i += 2;
		} else {
			v = w = c[i++];
		}
		/* every token but the last is summed; the last one is sum8 */
		prev_wire = wire;
		wire += w;
		if (ntok == 0)
			seed = v;
		else
			out[ntok - 1] = v;	/* scrambled for now, the checksum lands in the last slot */
		last = v;
		ntok++;
	}
	if (ntok < 2 || (prev_wire & 0xff) != last)
		return -1;
	for (i = 0; i < ntok - 2; i++)
		out[i] ^= kbp_key[(seed + i) & 0x3f];
	return ntok - 2;
}

static inline int kbp_esc(unsigned char *o, unsigned char b)
{
	if (b == 0x7d || b == 0x7e) {
		o[0] = 0x7d;
		o[1] = b ^ 0x20;
		return 2;
	}
	o[0] = b;
	return 1;
}

/* host -> keyboard frame of plain[n]; out needs 2 * n + 8 bytes; returns the frame length */
static inline int kbp_frame(const unsigned char *plain, int n, unsigned char seed, unsigned char *out)
{
	unsigned int sum = 0;
	int o = 3, i, k;

	out[0] = 0x7e;
	out[1] = 0x7e;
	out[2] = 0xff;
	for (i = -1; i < n; i++) {
		unsigned char b = i < 0 ? seed : plain[i] ^ kbp_key[(seed + i) & 0x3f];

		k = kbp_esc(out + o, b);
		while (k--)
			sum += out[o++];
	}
	o += kbp_esc(out + o, sum & 0xff);
	out[o++] = 0x7e;
	return o;
}

#endif
