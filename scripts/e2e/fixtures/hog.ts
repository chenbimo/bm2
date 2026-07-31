const chunks: Buffer[] = [];
for (let i = 0; i < 100; i++) {
  chunks.push(Buffer.alloc(1024 * 1024, 1));
}
Bun.serve({
  port: Number(process.env.BM2_APP_PORT ?? 3000),
  fetch() {
    return new Response("hog\n");
  },
});
