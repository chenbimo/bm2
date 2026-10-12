// Refuses SIGTERM so bm2 must escalate to SIGKILL after stop_timeout_ms.
process.on("SIGTERM", () => {});
Bun.serve({
  port: Number(process.env.BM2_APP_PORT ?? 3000),
  fetch() {
    return new Response("stubborn\n");
  },
});
