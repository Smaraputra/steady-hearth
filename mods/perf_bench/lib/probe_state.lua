-- Server-side state of the post-window probes: the benchmark sets `phase` to 'client' when the
-- measured window has ended, the client asks for it through perf_bench:probe_phase and reports
-- through perf_bench:probe_done, which sets `phase` to 'done' and keeps the client's `result`.
return { phase = 'idle', result = nil }
