// Modification notice: Changed in 2026 for the Port Radar Offline fork.
import Image from "next/image";
import type { ReactNode } from "react";
import { PressPanel } from "@/components/PressPanel";

/**
 * Launch gallery stills, rendered at 1270x760.
 * Screenshot each route, don't hand-draw mockups.
 */

const SLIDES = ["01", "02", "03", "04", "05", "06"] as const;

export function generateStaticParams() {
  return SLIDES.map((slide) => ({ slide }));
}

export default async function GallerySlide({
  params,
}: {
  params: Promise<{ slide: string }>;
}) {
  const { slide } = await params;

  return (
    <Frame>
      {slide === "01" && <Hero />}
      {slide === "02" && <AskSlide />}
      {slide === "03" && <OfflineSlide />}
      {slide === "04" && <StopSlide />}
      {slide === "05" && <MenuSlide />}
      {slide === "06" && <CloseSlide />}
    </Frame>
  );
}

function Frame({ children }: { children: ReactNode }) {
  return (
    <div
      className="relative overflow-hidden bg-paper text-ink"
      style={{ width: 1270, height: 760 }}
    >
      <div
        aria-hidden
        className="absolute inset-0"
        style={{
          background: `
            radial-gradient(ellipse 80% 55% at 50% 0%, rgba(255,255,255,0.95), transparent 58%),
            radial-gradient(ellipse 50% 45% at 85% 65%, rgba(13,148,136,0.10), transparent 52%),
            linear-gradient(180deg, #f5f6f8 0%, #eceef2 52%, #e4e7ee 100%)
          `,
        }}
      />
      <div className="relative flex h-full w-full items-center">{children}</div>
    </div>
  );
}

function Eyebrow({ children, color }: { children: ReactNode; color?: string }) {
  return (
    <p
      className="font-display text-[14px] font-semibold uppercase tracking-[0.16em]"
      style={{ color: color ?? "var(--signal)" }}
    >
      {children}
    </p>
  );
}

function Wordmark() {
  return (
    <div className="flex items-center gap-3">
      <Image src="/brand/app-icon.png" alt="" width={44} height={44} priority />
      <span className="font-display text-[24px] font-semibold tracking-[-0.035em] text-ink">
        Port Radar Offline
      </span>
    </div>
  );
}

function Hero() {
  return (
    <div className="grid w-full grid-cols-[1fr_540px] items-center gap-10 px-16">
      <div>
        <Wordmark />
        <h1 className="mt-8 font-display text-[52px] font-semibold leading-[1] tracking-[-0.045em] text-ink">
          The offline port manager
          <br />
          for Mac.
        </h1>
        <p className="mt-6 max-w-[30rem] text-[19px] font-light leading-relaxed text-muted">
          Every port your Mac is running — grouped by project, named in plain
          language, and stopped in one click.
        </p>
        <div className="mt-9 flex items-center gap-3">
          {["On-device", "No network", "Free"].map((t) => (
            <span
              key={t}
              className="inline-flex items-center rounded-full border border-line bg-white/70 px-4 py-2 text-[14px] font-medium text-ink/80"
            >
              {t}
            </span>
          ))}
        </div>
      </div>
      <div className="flex items-center justify-center">
        <PressPanel still="idle" scale={1.28} />
      </div>
    </div>
  );
}

function AskSlide() {
  return (
    <div className="grid w-full grid-cols-[1fr_540px] items-center gap-10 px-16">
      <div>
        <Eyebrow>Ask</Eyebrow>
        <h2 className="mt-4 font-display text-[50px] font-semibold leading-[1] tracking-[-0.045em] text-ink">
          What&apos;s on 5173?
          <br />
          <span className="text-muted">Just ask.</span>
        </h2>
        <p className="mt-6 max-w-[29rem] text-[19px] font-light leading-relaxed text-muted">
          Ask about any process. Apple&apos;s on-device model, or a local Ollama model
          you installed, reads the command, the project, the uptime — then tells you
          what it is and whether it&apos;s safe to stop. Nothing leaves your Mac.
        </p>
        <ul className="mt-8 space-y-3.5 text-[16px] text-ink/80">
          {[
            "“Is this safe to stop?”",
            "“Why has this been up 14 hours?”",
            "“Which project owns this port?”",
          ].map((q) => (
            <li key={q} className="flex items-start gap-3">
              <span className="mt-2 h-2 w-2 shrink-0 rounded-full bg-signal" />
              <span className="font-medium tracking-[-0.01em]">{q}</span>
            </li>
          ))}
        </ul>
      </div>
      <div className="flex items-center justify-center">
        <PressPanel still="ask" scale={1.28} />
      </div>
    </div>
  );
}

function OfflineSlide() {
  return (
    <div className="grid w-full grid-cols-[540px_1fr] items-center gap-10 px-16">
      <div className="flex items-center justify-center">
        <PressPanel still="stream" scale={1.28} />
      </div>
      <div>
        <Eyebrow>Offline</Eyebrow>
        <h2 className="mt-4 font-display text-[50px] font-semibold leading-[1] tracking-[-0.045em] text-ink">
          The answer streams in.
          <br />
          <span className="text-muted">Nothing streams out.</span>
        </h2>
        <p className="mt-6 max-w-[29rem] text-[19px] font-light leading-relaxed text-muted">
          Replies arrive token by token and Stop ends one mid-response. Ollama runs
          in a private service the app starts on 127.0.0.1 with cloud access off, and
          the model unloads when you close the chat.
        </p>
        <div className="mt-8 flex max-w-[30rem] flex-wrap gap-2.5">
          {[
            "Streamed replies",
            "Stop anytime",
            "Private local service",
            "In-memory only",
          ].map((t) => (
            <span
              key={t}
              className="inline-flex items-center rounded-full border border-line bg-white/70 px-4 py-2 text-[14px] font-medium text-ink/80"
            >
              {t}
            </span>
          ))}
        </div>
      </div>
    </div>
  );
}

function StopSlide() {
  return (
    <div className="grid w-full grid-cols-[1fr_540px] items-center gap-10 px-16">
      <div>
        <Eyebrow>Control</Eyebrow>
        <h2 className="mt-4 font-display text-[50px] font-semibold leading-[1] tracking-[-0.045em] text-ink">
          Stop anything.
          <br />
          <span className="text-muted">One click.</span>
        </h2>
        <p className="mt-6 max-w-[29rem] text-[19px] font-light leading-relaxed text-muted">
          Graceful stop or force quit, always with a confirmation — so you never
          take down the wrong thing. Zombie servers gone in one click.
        </p>
        <div className="mt-8 flex items-center gap-3">
          {["Confirm before stopping", "Force quit if it hangs"].map((t) => (
            <span
              key={t}
              className="inline-flex items-center rounded-full border border-line bg-white/70 px-4 py-2 text-[14px] font-medium text-ink/80"
            >
              {t}
            </span>
          ))}
        </div>
      </div>
      <div className="flex items-center justify-center">
        <PressPanel still="stop" scale={1.28} />
      </div>
    </div>
  );
}

function MenuSlide() {
  return (
    <div className="grid w-full grid-cols-[540px_1fr] items-center gap-10 px-16">
      <div className="flex items-center justify-center">
        <PressPanel still="menu" scale={1.28} />
      </div>
      <div>
        <Eyebrow>Every action, one menu</Eyebrow>
        <h2 className="mt-4 font-display text-[50px] font-semibold leading-[1] tracking-[-0.045em] text-ink">
          Ask, open,
          <br />
          <span className="text-muted">or shut it down.</span>
        </h2>
        <p className="mt-6 max-w-[29rem] text-[19px] font-light leading-relaxed text-muted">
          Everything you&apos;d do to a running process, from one menu — including
          opening the project straight in your editor.
        </p>
        <div className="mt-8 flex max-w-[30rem] flex-wrap gap-2.5">
          {[
            "Ask about process",
            "Reveal in Finder",
            "Open in Cursor",
            "Open in Terminal",
          ].map((t) => (
            <span
              key={t}
              className="inline-flex items-center rounded-full border border-line bg-white/70 px-4 py-2 text-[14px] font-medium text-ink/80"
            >
              {t}
            </span>
          ))}
        </div>
      </div>
    </div>
  );
}

function CloseSlide() {
  return (
    <div className="mx-auto flex w-full max-w-[820px] flex-col items-center px-20 text-center">
      <Image src="/brand/app-icon.png" alt="" width={132} height={132} priority />
      <h2 className="mt-8 font-display text-[64px] font-semibold leading-[1] tracking-[-0.045em] text-ink">
        Free for Mac.
      </h2>
      <p className="mt-5 text-[21px] font-light leading-relaxed text-muted">
        Lives in your menu bar. Explains every port. Stops the ones you don&apos;t
        need — all without a network call.
      </p>
      <div className="mt-9 flex items-center gap-3">
        {["On-device & private", "Scan · Ask · Stop", "Native macOS"].map((t) => (
          <span
            key={t}
            className="inline-flex items-center rounded-full border border-line bg-white/70 px-4 py-2 text-[15px] font-medium text-ink/80"
          >
            {t}
          </span>
        ))}
      </div>
    </div>
  );
}
