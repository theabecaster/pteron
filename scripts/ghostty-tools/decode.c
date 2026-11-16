// Decodes a captured Rex stream: GHOSTSNP snapshot, then the live VT bytes.
#include <ghostty/vt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_ms(void) {
  struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

int main(int argc, char **argv) {
  FILE *f = fopen(argv[1], "rb");
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  uint8_t *buf = malloc(n); fread(buf, 1, n, f); fclose(f);

  double t0 = now_ms();
  GhosttySnapshotDecoder dec = NULL;
  GhosttyResult r = ghostty_snapshot_decoder_new_buf(NULL, &dec, buf, n);
  bool on = true;
  ghostty_snapshot_decoder_set(dec, GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY, &on);
  GhosttyTerminal term = NULL;
  r = ghostty_snapshot_decoder_decode(dec, &term);
  size_t off = 0;
  ghostty_snapshot_decoder_get(dec, GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET, &off);
  ghostty_snapshot_decoder_free(dec);
  double t1 = now_ms();
  printf("decode result %d, snapshot %zu bytes of %ld, %.2f ms\n", r, off, n, t1 - t0);
  if (r != GHOSTTY_SUCCESS) return 1;

  uint16_t cols = 0, rows = 0;
  ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_COLS, &cols);
  ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
  size_t sb = 0; ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &sb);
  printf("grid %ux%u scrollback rows %zu\n", cols, rows, sb);
  printf("next bytes after snapshot: ");
  for (size_t i = off; i < off + 24 && i < (size_t)n; i++) printf("%c", buf[i] >= 32 && buf[i] < 127 ? buf[i] : '.');
  printf("\n");

  ghostty_terminal_vt_write(term, buf + off, n - off);



  GhosttyFormatter fmt = NULL;
  ghostty_formatter_terminal_new(NULL, &fmt, term);
  uint8_t *out = NULL; size_t outlen = 0;
  ghostty_formatter_format_alloc(fmt, NULL, &out, &outlen);
  // Print the last 600 bytes.
  size_t s = outlen > 600 ? outlen - 600 : 0;
  fwrite(out + s, 1, outlen - s, stdout);
  printf("\n");
  return 0;
}
