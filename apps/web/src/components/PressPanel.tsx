"use client";

import { AskOverlay, EllipsisMenu, PanelBody, StopOverlay } from "./AppDemo";

export type Still = "idle" | "menu" | "ask" | "tunnels" | "stop" | "stopped";

/**
 * Static render of the menu bar panel for press/launch screenshots.
 * Reuses the live demo's components so stills can't drift from the product.
 */
export function PressPanel({ still, scale = 1 }: { still: Still; scale?: number }) {
  const dimmed = still !== "idle";
  const highlight =
    still === "ask" || still === "menu"
      ? "ask"
      : still === "tunnels"
        ? "share"
        : still === "stop" || still === "stopped"
          ? "stop"
          : null;

  return (
    <div
      className="relative w-[420px] shrink-0"
      style={{ transform: `scale(${scale})`, transformOrigin: "center" }}
      aria-hidden
    >
      <div className="absolute -inset-x-10 -bottom-8 top-16 -z-10 rounded-[50%] bg-ink/[0.18] blur-3xl" />

      <div
        className="relative overflow-hidden rounded-[12px] border border-white/[0.08] text-[13px] text-white shadow-[0_22px_60px_rgba(8,10,16,0.45),0_2px_8px_rgba(8,10,16,0.25)]"
        style={{
          background:
            "linear-gradient(180deg, rgba(44,44,46,0.96) 0%, rgba(28,28,30,0.98) 100%)",
        }}
      >
        <PanelBody
          dimmed={dimmed}
          listening={still === "stopped" ? 3 : 4}
          showVite={still !== "stopped"}
          viteFading={false}
          removing={false}
          viteShared={still !== "stop"}
          highlight={highlight}
        />

        {still === "menu" && <EllipsisMenu />}
        {still === "ask" && <AskOverlay phase="reply" />}
        {still === "tunnels" && <TunnelsModal />}
        {still === "stop" && <StopOverlay phase="confirm" />}
        {still === "stopped" && <StopOverlay phase="done" />}
      </div>
    </div>
  );
}

/** Mirrors TunnelsModal in the Swift app — 340pt sheet, sized to its content. */
function TunnelsModal() {
  return (
    <div className="demo-panel absolute left-1/2 top-1/2 z-20 w-[340px] -translate-x-1/2 -translate-y-1/2 overflow-hidden rounded-[12px] border border-white/[0.14] bg-[#1f1f21] shadow-[0_0_28px_rgba(255,255,255,0.12),0_14px_28px_rgba(0,0,0,0.55)]">
      <div className="flex items-start justify-between px-3.5 pb-2.5 pt-3.5">
        <div>
          <p className="text-[14px] font-semibold text-white">Tunnels</p>
          <p className="mt-0.5 text-[10px] text-white/40">
            Cloudflare quick tunnels · public while active
          </p>
        </div>
        <span className="text-white/35">
          <svg width="15" height="15" viewBox="0 0 24 24" fill="currentColor">
            <path d="M12 2a10 10 0 1 0 .001 20.001A10 10 0 0 0 12 2Zm3.54 12.46-1.08 1.08L12 13.08l-2.46 2.46-1.08-1.08L10.92 12 8.46 9.54l1.08-1.08L12 10.92l2.46-2.46 1.08 1.08L13.08 12l2.46 2.46Z" />
          </svg>
        </span>
      </div>
      <div className="h-px bg-white/10" />

      <div className="p-3">
        <div className="rounded-[8px] bg-white/[0.09] p-2.5">
          <div className="flex items-center gap-1.5">
            <span className="text-[13px] font-medium text-white">node</span>
            <span className="font-mono text-[11px] text-white/40">:5173</span>
            <span className="ml-auto rounded-full bg-[#30d158]/20 px-[6px] py-px text-[10px] font-medium text-[#30d158]">
              Live
            </span>
          </div>
          <p className="mt-2 break-all font-mono text-[10px] leading-relaxed text-white/45">
            https://checkout-web-preview.trycloudflare.com
          </p>
          <div className="mt-2.5 flex items-center gap-2">
            <SheetButton>Copy URL</SheetButton>
            <SheetButton>Open</SheetButton>
            <span className="ml-auto" />
            <SheetButton destructive>Stop</SheetButton>
          </div>
        </div>
      </div>

      <div className="h-px bg-white/10" />
      <div className="flex items-center px-3.5 py-2.5">
        <span className="text-[11px] text-white/45">Stop all</span>
        <span className="ml-auto inline-flex h-[22px] items-center rounded-[6px] bg-[#0a84ff] px-3 text-[12px] font-medium text-white">
          Done
        </span>
      </div>
    </div>
  );
}

function SheetButton({
  children,
  destructive,
}: {
  children: string;
  destructive?: boolean;
}) {
  return (
    <span
      className={`inline-flex h-[21px] items-center rounded-[5px] px-2 text-[11.5px] font-medium ring-1 ${
        destructive
          ? "bg-white/[0.08] text-[#ff6b6b] ring-white/10"
          : "bg-white/[0.14] text-white/90 ring-white/10"
      }`}
    >
      {children}
    </span>
  );
}
