Bun.serve({
  port: Number(process.env.PORT ?? 3000),
  fetch() {
    return new Response(
      `slow ${process.env.BM2_APP_NAME}-${process.env.BM2_INSTANCE_ID}\n`,
    );
  },
});
