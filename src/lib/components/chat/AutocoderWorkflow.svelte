<script lang="ts">
  export type WorkflowResult = { stdout?: string; stderr?: string; exit_code?: number };
  export type WorkflowEvent = {
    type: string;
    status: string;
    step: number;
    kind?: string;
    language?: string;
    result?: WorkflowResult;
    stderr?: string;
  };

  export let events: WorkflowEvent[] = [];

  const langIcon = (lang?: string) => {
    const key = (lang || "python").toLowerCase();
    const map: Record<string, string> = {
      python: "🐍",
      py: "🐍",
      javascript: "🟨",
      js: "🟨",
      node: "🟩",
      go: "💙",
      golang: "💙",
      bash: "⬛",
      shell: "⬛",
    };
    return map[key] || "🧰";
  };

  const statusTone = (status: string) => {
    if (status === "completed") return "text-emerald-500";
    if (status === "failed" || status === "exhausted" || status === "no_fix")
      return "text-rose-500";
    if (status === "executing") return "text-amber-500";
    if (status === "fix_request") return "text-sky-500";
    return "text-slate-400";
  };

  const statusLabel = (status: string) => {
    const labels: Record<string, string> = {
      executing: "Executing",
      completed: "Completed",
      failed: "Failed",
      fix_request: "Requesting Fix",
      no_fix: "No Fix Returned",
      exhausted: "Retries Exhausted",
    };
    return labels[status] || status;
  };
</script>

<div class="border border-slate-800/50 rounded-xl bg-slate-900/60 p-4 space-y-3">
  <div class="flex items-center gap-3">
    <div class="text-2xl leading-none">{langIcon(events.at(-1)?.language)}</div>
    <div>
      <div class="text-sm uppercase tracking-wide text-slate-400">Autocoder Workflow</div>
      <div class="text-base font-semibold text-slate-100">
        {events.at(-1)?.language || "python"}
      </div>
    </div>
  </div>

  {#if events.length === 0}
    <div class="text-slate-400 text-sm">Awaiting workflow signals...</div>
  {:else}
    <div class="space-y-2">
      {#each events as ev (ev.step + '-' + ev.status)}
        <div class="rounded-lg bg-slate-800/60 p-3 border border-slate-800">
          <div class="flex items-center justify-between gap-3">
            <div class="text-sm text-slate-200 font-semibold">
              Step {ev.step} · {ev.language || "python"}
            </div>
            <div class={`text-xs font-semibold ${statusTone(ev.status)}`}>
              {statusLabel(ev.status)}
            </div>
          </div>

          {#if ev.result}
            <div class="mt-2 grid gap-1">
              <div class="text-xs text-slate-400">exit_code: {ev.result.exit_code ?? "?"}</div>
              {#if ev.result.stdout}
                <pre class="text-xs bg-slate-950/80 border border-slate-800 rounded p-2 overflow-auto text-emerald-200">{ev.result.stdout}</pre>
              {/if}
              {#if ev.result.stderr}
                <pre class="text-xs bg-slate-950/80 border border-slate-800 rounded p-2 overflow-auto text-rose-200">{ev.result.stderr}</pre>
              {/if}
            </div>
          {:else if ev.stderr}
            <pre class="mt-2 text-xs bg-slate-950/80 border border-slate-800 rounded p-2 overflow-auto text-rose-200">{ev.stderr}</pre>
          {/if}
        </div>
      {/each}
    </div>
  {/else}
</div>
