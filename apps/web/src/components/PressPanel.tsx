// Modification notice: Changed in 2026 for the Port Radar Offline fork.
"use client";

import { AskOverlay, EllipsisMenu, PanelBody, StopOverlay } from "./AppDemo";

export type Still = "idle" | "menu" | "ask" | "stream" | "stop" | "stopped";

/**
 * Static render of the menu bar panel for press/launch screenshots.
 * Reuses the live demo's components so stills can't drift from the product.
 */
export function PressPanel({ still, scale = 1 }: { still: Still; scale?: number }) {
  const dimmed = still !== "idle";
  const highlight =
    still === "ask" || still === "menu" || still === "stream"
      ? "ask"
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
          highlight={highlight}
        />

        {still === "menu" && <EllipsisMenu />}
        {still === "ask" && <AskOverlay phase="reply" />}
        {still === "stream" && <AskOverlay phase="streaming" />}
        {still === "stop" && <StopOverlay phase="confirm" />}
        {still === "stopped" && <StopOverlay phase="done" />}
      </div>
    </div>
  );
}
