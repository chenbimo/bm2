Bun.serve({
  port: Number(process.env.BM2_APP_PORT ?? 3000),
  fetch() {
    return new Response(
      `slow ${process.env.BM2_APP_NAME}-${process.env.BM2_INSTANCE_ID} ${process.env.BM2_E2E_ROLE} ${process.env.BM2_APP_PORT} ${process.env.BM2_APP_INSTANCE}\n`,
    );
  },
});
