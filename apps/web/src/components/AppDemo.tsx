"use client";

import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";

type Step =
  | "idle"
  | "move-ask"
  | "click-ask"
  | "ask"
  | "move-share"
  | "click-share"
  | "share"
  | "move-stop"
  | "click-stop"
  | "move-stop-confirm"
  | "click-stop-confirm"
  | "stop-working"
  | "stop-done";

type TargetId = "ask" | "share" | "stop" | "stop-confirm" | "rest";

/** One move → one click → hold panel. Slow enough to read. */
const SCRIPT: { step: Step; ms: number }[] = [
  { step: "idle", ms: 2200 },
  { step: "move-ask", ms: 1200 },
  { step: "click-ask", ms: 280 },
  { step: "ask", ms: 4800 },
  { step: "idle", ms: 1200 },
  { step: "move-share", ms: 1200 },
  { step: "click-share", ms: 280 },
  { step: "share", ms: 4200 },
  { step: "idle", ms: 1200 },
  { step: "move-stop", ms: 1200 },
  { step: "click-stop", ms: 280 },
  { step: "move-stop-confirm", ms: 1100 },
  { step: "click-stop-confirm", ms: 280 },
  { step: "stop-working", ms: 2000 },
  { step: "stop-done", ms: 1600 },
];

function targetForStep(step: Step): TargetId {
  if (step === "move-ask" || step === "click-ask") return "ask";
  if (step === "move-share" || step === "click-share") return "share";
  if (step === "move-stop" || step === "click-stop") return "stop";
  if (
    step === "move-stop-confirm" ||
    step === "click-stop-confirm" ||
    step === "stop-working"
  ) {
    return "stop-confirm";
  }
  return "rest";
}

function isStopFlow(step: Step): boolean {
  return (
    step === "click-stop" ||
    step === "move-stop-confirm" ||
    step === "click-stop-confirm" ||
    step === "stop-working" ||
    step === "stop-done"
  );
}

/** Animated MenuBarExtra demo — Ask (⋯) → Tunnels → Stop. */
export function AppDemo() {
  const [step, setStep] = useState<Step>("idle");
  const [reduced, setReduced] = useState(false);
  const [clickKey, setClickKey] = useState(0);
  const [cursor, setCursor] = useState({ x: 0, y: 0, ready: false });
  const [viteAlive, setViteAlive] = useState(true);

  const panelRef = useRef<HTMLDivElement>(null);

  const measure = useCallback((id: TargetId) => {
    const panel = panelRef.current;
    if (!panel) return;
    const el = panel.querySelector(`[data-demo-target="${id}"]`);
    if (!(el instanceof HTMLElement)) return;
    const pr = panel.getBoundingClientRect();
    const tr = el.getBoundingClientRect();
    setCursor({
      x: tr.left - pr.left + tr.width * 0.3,
      y: tr.top - pr.top + tr.height * 0.3,
      ready: true,
    });
  }, []);

  useEffect(() => {
    const mq = window.matchMedia("(prefers-reduced-motion: reduce)");
    setReduced(mq.matches);
    const onChange = () => setReduced(mq.matches);
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, []);

  useEffect(() => {
    if (reduced) return;
    let i = 0;
    let timer = 0;
    const tick = () => {
      const current = SCRIPT[i]!;
      setStep(current.step);
      if (current.step.startsWith("click-")) {
        setClickKey((k) => k + 1);
      }
      if (current.step === "stop-done") {
        setViteAlive(false);
      }
      timer = window.setTimeout(() => {
        i = (i + 1) % SCRIPT.length;
        if (i === 0) setViteAlive(true);
        tick();
      }, current.ms);
    };
    tick();
    return () => window.clearTimeout(timer);
  }, [reduced]);

  useLayoutEffect(() => {
    // Modal targets mount a frame later — retry once
    measure(targetForStep(step));
    const t = window.setTimeout(() => measure(targetForStep(step)), 40);
    return () => window.clearTimeout(t);
  }, [step, measure, viteAlive]);

  useEffect(() => {
    const onResize = () => measure(targetForStep(step));
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, [step, measure]);

  const openOverlay =
    step === "ask" || step === "click-ask"
      ? "ask"
      : step === "share" || step === "click-share"
        ? "share"
        : isStopFlow(step)
          ? "stop"
          : null;

  const stopPhase: "confirm" | "working" | "done" =
    step === "stop-working"
      ? "working"
      : step === "stop-done"
        ? "done"
        : "confirm";

  const highlight =
    step === "move-ask" || step === "click-ask" || step === "ask"
      ? "ask"
      : step === "move-share" || step === "click-share" || step === "share"
        ? "share"
        : step === "move-stop" || step === "click-stop"
          ? "stop"
          : null;

  const isClicking = step.startsWith("click-");
  const removing = step === "stop-done";
  const showVite = viteAlive || step === "stop-working" || removing;
  const viteFading = step === "stop-working" || removing;
  const listening = removing || !viteAlive ? 3 : 4;

  return (
    <div className="relative mx-auto w-full max-w-[420px]" aria-hidden>
      <div className="absolute -inset-x-10 -bottom-8 top-20 -z-10 rounded-[50%] bg-ink/[0.18] blur-3xl" />

      <div className="mb-2.5 flex justify-end pr-1">
        <div className="inline-flex h-7 items-center rounded-md px-2 text-ink/70">
          <AntennaIcon className="h-[15px] w-[15px]" />
        </div>
      </div>

      <div
        ref={panelRef}
        className="relative overflow-hidden rounded-[12px] border border-white/[0.08] text-[13px] text-white shadow-[0_22px_60px_rgba(8,10,16,0.45),0_2px_8px_rgba(8,10,16,0.25)]"
        style={{
          background:
            "linear-gradient(180deg, rgba(44,44,46,0.96) 0%, rgba(28,28,30,0.98) 100%)",
        }}
      >
        <div
          className={`transition-opacity duration-500 ${openOverlay ? "opacity-25" : "opacity-100"}`}
        >
          <div className="flex items-center justify-between px-3 py-2">
            <span className="text-[13px] font-semibold tracking-[-0.01em]">Port Radar</span>
            <span className="text-[11px] text-white/40">{listening} listening</span>
          </div>
          <div className="h-px bg-white/[0.1]" />

          <div className="pb-1">
            <GroupHeader framework="next" name="checkout-web" path="~/dev/checkout-web" />
            <ServerRow name="node" pid="48201" command="next dev" port="3000" uptime="2h 14m" />
            {showVite && (
              <div
                className={`origin-top transition-all duration-700 ease-out ${
                  viteFading ? "opacity-35" : "opacity-100"
                } ${removing ? "-mt-1 max-h-0 overflow-hidden py-0 opacity-0" : "max-h-20"}`}
              >
                <ServerRow
                  name="node"
                  pid="48244"
                  command="vite"
                  port="5173"
                  uptime="2h 14m"
                  shared={step !== "stop-working" && !removing}
                  highlight={highlight === "ask" || highlight === "stop" ? highlight : null}
                  demoRow
                />
              </div>
            )}
            <GroupHeader framework="python" name="api" path="~/dev/api" />
            <ServerRow
              name="Python"
              pid="39112"
              command="uvicorn main:app --reload"
              port="8000"
              uptime="6h 02m"
            />
            <GroupHeader name="Other" />
            <ServerRow
              name="Python"
              pid="12884"
              command="/usr/bin/python3 -m http.server 8128"
              port="8128"
              uptime="14h 01m"
              orphan
            />
          </div>

          <div className="h-px bg-white/[0.1]" />
          <FooterItem
            icon="network"
            label="Tunnels"
            trailing={listening === 4 ? "1" : undefined}
            demoTarget="share"
            active={highlight === "share"}
          />
          <div className="h-px bg-white/[0.1]" />
          <FooterItem icon="gear" label="Settings" />
          <div className="h-px bg-white/[0.1]" />
          <FooterItem icon="power" label="Quit Port Radar" />
        </div>

        <span
          data-demo-target="rest"
          className="pointer-events-none absolute left-1/2 top-[42%] h-1 w-1 -translate-x-1/2"
        />

        {openOverlay === "ask" && <AskOverlay />}
        {openOverlay === "share" && <ShareOverlay />}
        {openOverlay === "stop" && <StopOverlay phase={stopPhase} />}

        {!reduced && cursor.ready && (
          <Cursor x={cursor.x} y={cursor.y} click={isClicking} clickKey={clickKey} />
        )}
      </div>

      {!reduced && (
        <p className="mt-3 text-center text-[11px] font-medium tracking-wide text-faint">
          {captionFor(step)}
        </p>
      )}
    </div>
  );
}

function captionFor(step: Step): string {
  switch (step) {
    case "move-ask":
    case "click-ask":
    case "ask":
      return "Ask Apple Intelligence what a process is";
    case "move-share":
    case "click-share":
    case "share":
      return "Share a live Cloudflare link in one click";
    case "move-stop":
    case "click-stop":
    case "move-stop-confirm":
    case "click-stop-confirm":
      return "Stop a process — with confirmation";
    case "stop-working":
      return "Waiting for the process to exit…";
    case "stop-done":
      return "Gone from the list";
    default:
      return "See every localhost server in your menu bar";
  }
}

function Cursor({
  x,
  y,
  click,
  clickKey,
}: {
  x: number;
  y: number;
  click: boolean;
  clickKey: number;
}) {
  return (
    <div
      className="pointer-events-none absolute z-30 transition-[left,top,transform] duration-[1100ms] ease-[cubic-bezier(0.22,1,0.36,1)]"
      style={{
        left: x,
        top: y,
        transform: click ? "scale(0.86)" : "scale(1)",
      }}
    >
      <svg width="22" height="22" viewBox="0 0 24 24" className="drop-shadow-[0_2px_6px_rgba(0,0,0,0.55)]">
        <path
          d="M5.5 3.5l13 8.2-5.8 1.4 2.6 6.4-2.4 1-2.7-6.5-4.7 4.1V3.5z"
          fill="#f5f5f7"
          stroke="#0c0e14"
          strokeWidth="1"
          strokeLinejoin="round"
        />
      </svg>
      {click && (
        <span
          key={clickKey}
          className="demo-click-ripple absolute left-1 top-1 h-6 w-6 -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-white/70 bg-white/25"
        />
      )}
    </div>
  );
}

function AskOverlay() {
  return (
    <div className="demo-panel absolute inset-3 z-20 flex flex-col overflow-hidden rounded-[12px] border border-white/14 bg-[#1c1c1e] shadow-[0_20px_50px_rgba(0,0,0,0.55)]">
      <div className="flex items-start justify-between px-3 pb-2 pt-3">
        <div>
          <p className="text-[13px] font-semibold text-white">Ask about process</p>
          <p className="mt-0.5 font-mono text-[10px] text-white/40">
            node · localhost:5173 · pid 48244
          </p>
        </div>
        <span className="text-white/35">✕</span>
      </div>
      <div className="h-px bg-white/10" />
      <div className="flex-1 space-y-2.5 overflow-hidden px-3 py-3">
        <div className="demo-fade flex justify-end" style={{ animationDelay: "120ms" }}>
          <div className="max-w-[88%] rounded-[10px] bg-[#0a84ff]/22 px-2.5 py-2 text-[12px] leading-snug text-white/95">
            What is this and can I kill it?
          </div>
        </div>
        <div className="demo-fade flex justify-start" style={{ animationDelay: "550ms" }}>
          <div className="max-w-[94%] rounded-[10px] bg-white/[0.07] px-2.5 py-2 text-[12px] leading-snug text-white/90">
            Vite for <span className="font-mono text-[11px] text-teal-300">checkout-web</span>.
            Safe to kill — restart with{" "}
            <span className="font-mono text-[11px]">npm run dev</span>.
          </div>
        </div>
      </div>
    </div>
  );
}

function ShareOverlay() {
  return (
    <div className="demo-panel absolute inset-3 z-20 overflow-hidden rounded-[12px] border border-white/14 bg-[#1c1c1e] shadow-[0_20px_50px_rgba(0,0,0,0.55)]">
      <div className="flex items-start justify-between px-3 pb-2 pt-3">
        <div>
          <p className="text-[13px] font-semibold text-white">Tunnels</p>
          <p className="mt-0.5 text-[10px] text-white/40">Cloudflare · public while active</p>
        </div>
        <span className="text-white/35">✕</span>
      </div>
      <div className="h-px bg-white/10" />
      <div className="demo-fade p-3" style={{ animationDelay: "150ms" }}>
        <div className="rounded-[10px] bg-white/[0.06] p-3 ring-1 ring-white/8">
          <div className="flex items-center gap-2">
            <span className="text-[13px] font-medium text-white">node</span>
            <span className="font-mono text-[11px] text-white/40">:5173</span>
            <span className="ml-auto inline-flex items-center gap-1 rounded-full bg-[#30d158]/18 px-2 py-0.5 text-[10px] font-semibold text-[#30d158]">
              <span className="h-1.5 w-1.5 rounded-full bg-[#30d158]" />
              Live
            </span>
          </div>
          <p className="mt-2 break-all font-mono text-[11px] text-[#7dd3fc]">
            https://checkout-web-preview.trycloudflare.com
          </p>
          <div className="mt-3 flex gap-2">
            <span className="inline-flex h-8 flex-1 items-center justify-center rounded-[8px] bg-white/10 text-[12px] font-semibold text-white/90">
              Copy URL
            </span>
            <span className="inline-flex h-8 flex-1 items-center justify-center rounded-[8px] bg-[#c62828]/25 text-[12px] font-semibold text-[#ff8a80]">
              Stop
            </span>
          </div>
        </div>
      </div>
    </div>
  );
}

function StopOverlay({ phase }: { phase: "confirm" | "working" | "done" }) {
  return (
    <div className="demo-panel absolute inset-x-5 inset-y-auto top-[28%] z-20 overflow-hidden rounded-[12px] border border-white/14 bg-[#2c2c2e] p-4 shadow-[0_20px_50px_rgba(0,0,0,0.55)]">
      <p className="text-[14px] font-semibold text-white">Stop node?</p>
      <p className="mt-1 font-mono text-[11px] text-white/40">
        localhost:5173 · pid 48244
      </p>

      {phase === "confirm" && (
        <>
          <p className="mt-2.5 text-[12px] leading-relaxed text-white/50">
            Asks the process to quit (SIGTERM). Force kills after a few seconds if it
            doesn&apos;t exit.
          </p>
          <div className="mt-4 flex gap-2">
            <span className="inline-flex h-9 flex-1 items-center justify-center rounded-[8px] bg-[#34c759]/70 text-[13px] font-semibold text-white">
              Cancel
            </span>
            <span
              data-demo-target="stop-confirm"
              className="inline-flex h-9 flex-1 items-center justify-center rounded-[8px] bg-[#e04848]/85 text-[13px] font-semibold text-white ring-1 ring-white/15"
            >
              Stop
            </span>
          </div>
        </>
      )}

      {phase === "working" && (
        <div className="mt-5 flex items-center gap-2.5 py-2">
          <span className="demo-spinner h-4 w-4 rounded-full border-2 border-white/20 border-t-white/90" />
          <span className="text-[13px] text-white/70">Stopping…</span>
          <span
            data-demo-target="stop-confirm"
            className="pointer-events-none absolute bottom-3 right-6 h-2 w-2"
          />
        </div>
      )}

      {phase === "done" && (
        <div className="mt-5 flex items-center gap-2.5 py-2">
          <span className="flex h-5 w-5 items-center justify-center rounded-full bg-[#30d158]/25 text-[#30d158]">
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
              <path d="M5 13l4 4L19 7" />
            </svg>
          </span>
          <span className="text-[13px] font-medium text-white">Stopped</span>
        </div>
      )}
    </div>
  );
}

function GroupHeader({
  name,
  path,
  framework,
}: {
  name: string;
  path?: string;
  framework?: "next" | "python";
}) {
  return (
    <div className="flex items-center gap-1.5 px-3 pb-0.5 pt-2">
      {framework === "next" && <NextMark />}
      {framework === "python" && <PythonMark />}
      <span className="text-[12px] font-semibold text-white/95">{name}</span>
      {path && <span className="min-w-0 truncate text-[10px] text-white/30">{path}</span>}
    </div>
  );
}

function ServerRow({
  name,
  pid,
  command,
  port,
  uptime,
  orphan,
  shared,
  highlight,
  demoRow,
}: {
  name: string;
  pid: string;
  command: string;
  port: string;
  uptime: string;
  orphan?: boolean;
  shared?: boolean;
  highlight?: "ask" | "stop" | null;
  demoRow?: boolean;
}) {
  const isFocus = Boolean(highlight);
  return (
    <div
      className={`px-3 py-1.5 transition-colors duration-300 ${
        isFocus ? "bg-white/[0.06]" : ""
      }`}
    >
      <div className="flex items-center gap-1.5">
        <span
          className={`h-[7px] w-[7px] shrink-0 rounded-full ${
            orphan ? "bg-[#ff9f0a]" : "bg-[#30d158]"
          }`}
        />
        <span className="text-[13px] font-medium text-white">{name}</span>
        {shared && (
          <span className="rounded-full bg-cyan-400/20 px-[5px] py-px text-[10px] font-medium text-cyan-300">
            Shared
          </span>
        )}
        {orphan && (
          <span className="rounded-full bg-orange-400/20 px-[5px] py-px text-[10px] font-medium text-orange-300">
            Orphan
          </span>
        )}
        <span className="ml-auto shrink-0 font-mono text-[10px] tabular-nums text-white/30">
          {uptime}
        </span>
        <span className="shrink-0 font-mono text-[11px] tabular-nums text-white/45">{port}</span>
        <span className="flex shrink-0 items-center gap-[5px] text-white/40">
          <IconWrap active={false}>
            <SafariIcon />
          </IconWrap>
          <IconWrap
            active={highlight === "ask"}
            demoTarget={demoRow ? "ask" : undefined}
          >
            <EllipsisIcon />
          </IconWrap>
          <IconWrap
            active={highlight === "stop"}
            demoTarget={demoRow ? "stop" : undefined}
          >
            <StopIcon />
          </IconWrap>
          <IconWrap active={false}>
            <ForceIcon />
          </IconWrap>
        </span>
      </div>
      <div className="mt-0.5 flex min-w-0 items-center gap-1.5 pl-[13px] text-[10px] text-white/30">
        <span className="shrink-0">pid {pid}</span>
        <span className="min-w-0 truncate">{command}</span>
      </div>
    </div>
  );
}

function IconWrap({
  active,
  children,
  demoTarget,
}: {
  active: boolean;
  children: ReactNode;
  demoTarget?: TargetId;
}) {
  return (
    <span
      data-demo-target={demoTarget}
      className={`inline-flex rounded-md p-0.5 transition duration-300 ${
        active ? "scale-110 bg-white/15 text-white ring-1 ring-white/25" : ""
      }`}
    >
      {children}
    </span>
  );
}

function FooterItem({
  icon,
  label,
  trailing,
  demoTarget,
  active,
}: {
  icon: "network" | "gear" | "power";
  label: string;
  trailing?: string;
  demoTarget?: TargetId;
  active?: boolean;
}) {
  return (
    <div
      data-demo-target={demoTarget}
      className={`flex items-center gap-2 px-3 py-[9px] text-[13px] text-white/90 transition-colors duration-300 ${
        active ? "bg-white/[0.08]" : ""
      }`}
    >
      <span className={`text-white/45 ${active ? "text-white" : ""}`}>
        {icon === "network" && <NetworkIcon />}
        {icon === "gear" && <GearIcon />}
        {icon === "power" && <PowerIcon />}
      </span>
      <span className={active ? "font-medium text-white" : ""}>{label}</span>
      {trailing && <span className="ml-auto text-[11px] text-white/35">{trailing}</span>}
    </div>
  );
}

function AntennaIcon({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
      <path d="M4.5 14.5a8 8 0 0 1 15 0" />
      <path d="M7.5 17a4.5 4.5 0 0 1 9 0" />
      <circle cx="12" cy="19.5" r="1.2" fill="currentColor" stroke="none" />
      <path d="M12 4v8" />
    </svg>
  );
}

function NextMark() {
  return (
    <svg width="14" height="14" viewBox="0 0 14 14" className="shrink-0 text-white/45" fill="none" stroke="currentColor" strokeWidth="1.15" strokeLinecap="round" strokeLinejoin="round">
      <rect x="1.2" y="1.2" width="11.6" height="11.6" rx="2.4" />
      <path d="M4.5 10.5V3.5L9.5 10.5M9.5 10.5V3.5" />
    </svg>
  );
}

function PythonMark() {
  return (
    <svg width="14" height="14" viewBox="0 0 14 14" className="shrink-0 text-white/45" fill="none" stroke="currentColor" strokeWidth="1.1">
      <circle cx="5.2" cy="5" r="3.2" />
      <circle cx="8.8" cy="9" r="3.2" />
    </svg>
  );
}

function SafariIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7">
      <circle cx="12" cy="12" r="9" />
      <path d="M15.5 8.5l-2.2 5.8-5.8 2.2 2.2-5.8z" fill="currentColor" stroke="none" opacity="0.55" />
      <path d="M15.5 8.5l-2.2 5.8-5.8 2.2 2.2-5.8z" />
    </svg>
  );
}

function EllipsisIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7">
      <circle cx="12" cy="12" r="9" />
      <circle cx="8" cy="12" r="1.1" fill="currentColor" stroke="none" />
      <circle cx="12" cy="12" r="1.1" fill="currentColor" stroke="none" />
      <circle cx="16" cy="12" r="1.1" fill="currentColor" stroke="none" />
    </svg>
  );
}

function StopIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7">
      <circle cx="12" cy="12" r="9" />
      <rect x="9" y="9" width="6" height="6" rx="0.8" fill="currentColor" stroke="none" />
    </svg>
  );
}

function ForceIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7">
      <circle cx="12" cy="12" r="9" />
      <path d="M13 6.5L9.5 13h3L11 17.5 14.5 11h-3L13 6.5z" fill="currentColor" stroke="none" />
    </svg>
  );
}

function NetworkIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round">
      <circle cx="12" cy="12" r="2.5" />
      <path d="M12 2v3M12 19v3M2 12h3M19 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M5.6 18.4l2.1-2.1M16.3 7.7l2.1-2.1" />
    </svg>
  );
}

function GearIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7">
      <circle cx="12" cy="12" r="3" />
      <path d="M12 2.5v2.2M12 19.3v2.2M4.5 4.5l1.6 1.6M17.9 17.9l1.6 1.6M2.5 12h2.2M19.3 12h2.2M4.5 19.5l1.6-1.6M17.9 6.1l1.6-1.6" />
    </svg>
  );
}

function PowerIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
      <path d="M12 3v9" />
      <path d="M7.2 6.3a7.5 7.5 0 1 0 9.6 0" />
    </svg>
  );
}
