const chunks: Buffer[] = [];
for (let i = 0; i < 100; i++) {
  chunks.push(Buffer.alloc(1024 * 1024, 1));
}
Bun.serve({
  port: Number(process.env.PORT ?? 3000),
  fetch() {
    return new Response("hog\n");
  },
});
