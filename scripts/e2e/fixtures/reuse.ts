Bun.serve({
  port: Number(process.env.BM2_APP_PORT ?? 3000),
  reusePort: true,
  fetch() {
    return new Response(
      `reuse ${process.env.BM2_APP_NAME}-${process.env.BM2_INSTANCE_ID} pid=${process.pid}\n`,
    );
  },
});
