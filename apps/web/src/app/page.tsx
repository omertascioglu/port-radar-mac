import Image from "next/image";
import type { ReactNode } from "react";
import { AppDemo } from "@/components/AppDemo";
import { Reveal } from "@/components/Reveal";
import { site } from "@/lib/site";

export default function HomePage() {
  return (
    <div className="relative min-h-full overflow-x-hidden bg-paper text-ink">
      <Atmosphere />
      <Nav />
      <Hero />
      <Features />
      <Download />
      <Footer />
    </div>
  );
}

function Atmosphere() {
  return (
    <div aria-hidden className="pointer-events-none fixed inset-0 -z-10">
      <div
        className="absolute inset-0"
        style={{
          background: `
            radial-gradient(ellipse 80% 50% at 50% 0%, rgba(255,255,255,0.9), transparent 55%),
            radial-gradient(ellipse 45% 40% at 80% 60%, rgba(13,148,136,0.07), transparent 50%),
            linear-gradient(180deg, #f5f6f8 0%, #eceef2 50%, #e6e9ef 100%)
          `,
        }}
      />
    </div>
  );
}

function Nav() {
  return (
    <nav className="nav-enter mx-auto flex w-full max-w-[1120px] items-center justify-between px-6 pt-7 md:px-10">
      <a href="#top" className="flex items-center gap-3">
        <Image
          src="/brand/app-icon.png"
          alt=""
          width={48}
          height={48}
          className="h-12 w-12"
          priority
        />
        <span className="font-display text-[26px] font-semibold leading-none tracking-[-0.035em] text-ink">
          Port Radar
        </span>
      </a>
      <div className="flex items-center gap-2">
        <a
          href={site.githubUrl}
          target="_blank"
          rel="noopener noreferrer"
          aria-label="Port Radar on GitHub"
          className="inline-flex h-10 items-center gap-2 rounded-[11px] border border-line bg-white/60 px-3.5 text-[14px] font-semibold text-ink/75 transition-colors hover:border-ink/20 hover:bg-white hover:text-ink"
        >
          <GitHubIcon />
          <span className="hidden sm:inline">Star on GitHub</span>
        </a>
        <a
          href={site.downloadUrl}
          className="download-cta-sm inline-flex h-10 items-center self-center rounded-[11px] px-4 text-[14px] font-semibold"
        >
          Download
        </a>
      </div>
    </nav>
  );
}

/**
 * Product Hunt's featured badge. Served as a remote SVG from their widget API,
 * so it stays a plain <img> rather than going through next/image.
 */
function ProductHuntBadge() {
  return (
    <a
      href={site.productHuntUrl}
      target="_blank"
      rel="noopener noreferrer"
      className="inline-flex transition-opacity hover:opacity-80"
    >
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img
        src={site.productHuntBadge}
        alt={`${site.name} — featured on Product Hunt`}
        width={250}
        height={54}
        className="h-12 w-auto"
      />
    </a>
  );
}

function GitHubIcon({ size = 17 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="currentColor" aria-hidden>
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-2.91-.88-2.91-2.79 0-.81.29-1.48.77-2-.08-.2-.34-1 .07-2.08 0 0 .62-.2 2.03.76a6.8 6.8 0 0 1 1.85-.25c.63 0 1.26.08 1.85.25 1.41-.96 2.03-.76 2.03-.76.41 1.08.15 1.88.07 2.08.48.52.77 1.19.77 2 0 1.92-1.14 2.59-2.92 2.79.3.26.56.76.56 1.54 0 1.11-.01 2.01-.01 2.29 0 .21.15.46.55.38A7.99 7.99 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
    </svg>
  );
}

function Hero() {
  return (
    <header id="top" className="relative mx-auto w-full max-w-[1120px] px-6 pb-10 pt-8 md:px-10 md:pt-12">
      <div className="mx-auto max-w-[42rem] text-center">
        <h1 className="enter font-display text-[clamp(2.15rem,5.4vw,3.65rem)] font-semibold leading-[1.02] tracking-[-0.045em] text-ink">
          Ask AI what&apos;s
          <br />
          running on your Mac.
        </h1>
        <p className="enter-d1 mx-auto mt-4 max-w-[36rem] text-[1.05rem] font-light leading-relaxed text-muted md:text-[1.12rem]">
          Mystery ports. Forgotten Vite servers. Random{" "}
          <span className="font-mono text-[0.95em] text-ink/70">node</span> eating CPU.
          Port Radar finds everything listening — then{" "}
          <span className="font-medium text-ink">Apple Intelligence</span> tells you
          what it is, why it&apos;s there, and if it&apos;s safe to stop. On-device.
          Nothing leaves your Mac.
        </p>

        {/* Primary CTA — first viewport, no scroll required */}
        <div className="enter-d2 mt-7 flex flex-col items-center gap-2.5">
          <a
            href={site.downloadUrl}
            className="download-cta inline-flex h-[3.75rem] min-w-[17.5rem] items-center justify-center gap-3 rounded-[16px] px-10 text-[17px] font-semibold tracking-[-0.015em]"
          >
            <span className="flex items-center gap-3">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
                <path d="M18.71 19.5C17.88 20.74 17 21.95 15.66 21.97C14.32 22 13.89 21.18 12.37 21.18C10.84 21.18 10.37 21.95 9.1 22C7.79 22.05 6.8 20.68 5.96 19.47C4.25 16.45 2.93 11.27 4.7 7.82C5.57 6.11 7.3 5.09 9.17 5.07C10.46 5.04 11.68 5.95 12.5 5.95C13.32 5.95 14.8 4.85 16.39 5.03C17.07 5.06 18.9 5.3 20.16 7.07C20.05 7.14 17.73 8.51 17.75 11.31C17.78 14.67 20.56 15.76 20.6 15.77C20.56 15.87 20.15 17.32 19.12 18.8L18.71 19.5ZM13 3.5C13.73 2.67 14.94 2.04 15.94 2C16.07 3.17 15.6 4.35 14.9 5.19C14.21 6.04 13.07 6.7 11.95 6.61C11.8 5.46 12.36 4.26 13 3.5Z" />
              </svg>
              Download for Mac
              <span className="ml-0.5 inline-flex h-7 w-7 items-center justify-center rounded-full bg-white/10 ring-1 ring-white/15">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                  <path d="M12 4v12" />
                  <path d="M7 12l5 5 5-5" />
                  <path d="M5 20h14" />
                </svg>
              </span>
            </span>
          </a>
          <p className="text-[12px] font-medium text-faint">
            Free &amp; open source · Apple Intelligence · on-device
          </p>
        </div>
      </div>

      <div className="enter-d3 relative mx-auto mt-10 max-w-[680px] md:mt-12">
        <AppDemo />
      </div>
    </header>
  );
}


function Features() {
  return (
    <section id="how" className="relative border-t border-line">
      {/* AI ask */}
      <div className="relative overflow-hidden">
        <div
          aria-hidden
          className="pointer-events-none absolute inset-0"
          style={{
            background: `
              radial-gradient(ellipse 70% 80% at 85% 40%, rgba(13,148,136,0.09), transparent 55%),
              radial-gradient(ellipse 50% 60% at 10% 80%, rgba(12,14,20,0.04), transparent 50%)
            `,
          }}
        />

        <div className="relative mx-auto grid max-w-[1120px] items-center gap-12 px-6 py-20 md:grid-cols-2 md:gap-16 md:px-10 md:py-28">
          <Reveal>
            <p className="font-display text-[13px] font-semibold uppercase tracking-[0.14em] text-signal">
              Apple Intelligence
            </p>
            <h2 className="mt-3 font-display text-[clamp(2rem,4vw,3.1rem)] font-semibold leading-[1.05] tracking-[-0.04em] text-ink">
              What&apos;s on 5173?
              <br />
              <span className="text-muted">Just ask.</span>
            </h2>
            <p className="mt-5 max-w-[28rem] text-[1.05rem] font-light leading-relaxed text-muted">
              Pick any process. Apple Intelligence reads the command, project, and
              context — then tells you what it is, why it&apos;s running, and whether
              you should stop it. On-device. Private. No cloud.
            </p>
            <ul className="mt-8 space-y-3 text-[14px] text-ink/80">
              {[
                "“Is this safe to stop?”",
                "“Why has this been up 14 hours?”",
                "“Which project owns this port?”",
              ].map((q) => (
                <li key={q} className="flex items-start gap-3">
                  <span className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-signal" />
                  <span className="font-medium tracking-[-0.01em]">{q}</span>
                </li>
              ))}
            </ul>
          </Reveal>

          <Reveal delay={120}>
            <AskChatMock />
          </Reveal>
        </div>
      </div>

      {/* Cloudflare share — same visual weight as AI */}
      <div className="relative overflow-hidden border-t border-line">
        <div
          aria-hidden
          className="pointer-events-none absolute inset-0"
          style={{
            background: `
              radial-gradient(ellipse 65% 70% at 15% 45%, rgba(246,128,33,0.10), transparent 55%),
              radial-gradient(ellipse 40% 50% at 90% 20%, rgba(13,148,136,0.06), transparent 50%)
            `,
          }}
        />

        <div className="relative mx-auto grid max-w-[1120px] items-center gap-12 px-6 py-20 md:grid-cols-2 md:gap-16 md:px-10 md:py-28">
          <Reveal>
            <ShareTunnelMock />
          </Reveal>

          <Reveal delay={120} className="order-first md:order-none">
            <p className="font-display text-[13px] font-semibold uppercase tracking-[0.14em] text-[#f6821f]">
              Cloudflare Tunnel
            </p>
            <h2 className="mt-3 font-display text-[clamp(2rem,4vw,3.1rem)] font-semibold leading-[1.05] tracking-[-0.04em] text-ink">
              Localhost → live link.
              <br />
              <span className="text-muted">One click.</span>
            </h2>
            <p className="mt-5 max-w-[30rem] text-[1.05rem] font-light leading-relaxed text-muted">
              Shipping a preview to a teammate or client? Hit Share. Port Radar
              spins up a Cloudflare tunnel and hands you a public URL for your
              local app — in seconds. No CLI. No account dance. No ngrok ritual.
            </p>
            <div className="mt-8 flex flex-wrap gap-2.5">
              {[
                "One-button share",
                "Auto-installs cloudflared",
                "Copy public URL",
                "Stop anytime",
              ].map((t) => (
                <span
                  key={t}
                  className="inline-flex items-center rounded-full border border-line bg-white/60 px-3.5 py-1.5 text-[12.5px] font-medium text-ink/80"
                >
                  {t}
                </span>
              ))}
            </div>
          </Reveal>
        </div>
      </div>

      {/* Supporting moves */}
      <div className="border-t border-line bg-ink/[0.03]">
        <div className="mx-auto grid max-w-[1120px] gap-0 md:grid-cols-2">
          <Capability
            eyebrow="Scan"
            title="See every listening port"
            body="Vite, Next, Python, Docker, orphans — grouped by project."
            visual={<PortsVisual />}
          />
          <Capability
            eyebrow="Control"
            title="Stop it cleanly"
            body="Graceful stop or force quit — with confirmation. No more hunting PIDs."
            visual={<ActionsVisual />}
            border
            delay={100}
          />
        </div>
      </div>
    </section>
  );
}

function Capability({
  eyebrow,
  title,
  body,
  visual,
  border,
  delay = 0,
}: {
  eyebrow: string;
  title: string;
  body: string;
  visual: ReactNode;
  border?: boolean;
  delay?: number;
}) {
  return (
    <Reveal
      delay={delay}
      className={`flex flex-col justify-between gap-8 px-6 py-12 md:px-10 md:py-14 ${
        border ? "border-t border-line md:border-l md:border-t-0" : ""
      }`}
    >
      <div>
        <p className="text-[12px] font-semibold uppercase tracking-[0.14em] text-faint">{eyebrow}</p>
        <h3 className="mt-2 font-display text-[1.55rem] font-semibold tracking-[-0.03em] text-ink">
          {title}
        </h3>
        <p className="mt-2 max-w-sm text-[15px] font-light leading-relaxed text-muted">{body}</p>
      </div>
      {visual}
    </Reveal>
  );
}

function AskChatMock() {
  return (
    <div className="relative mx-auto w-full max-w-[380px]">
      <div
        aria-hidden
        className="absolute -inset-6 -z-10 rounded-[40%] bg-ink/20 blur-3xl"
      />
      <div
        className="overflow-hidden rounded-[14px] border border-white/12 shadow-[0_28px_70px_rgba(8,10,16,0.5)]"
        style={{
          background: "linear-gradient(180deg, #2c2c2e 0%, #1c1c1e 100%)",
        }}
      >
        <div className="flex items-start justify-between px-3.5 pb-2.5 pt-3.5">
          <div>
            <p className="text-[14px] font-semibold text-white">Ask about process</p>
            <p className="mt-0.5 font-mono text-[10px] text-white/40">
              node · localhost:5173 · pid 48244
            </p>
          </div>
          <span className="text-white/35">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
              <path d="M12 2a10 10 0 1 0 .001 20.001A10 10 0 0 0 12 2Zm3.54 12.46-1.08 1.08L12 13.08l-2.46 2.46-1.08-1.08L10.92 12 8.46 9.54l1.08-1.08L12 10.92l2.46-2.46 1.08 1.08L13.08 12l2.46 2.46Z" />
            </svg>
          </span>
        </div>
        <div className="h-px bg-white/10" />

        <div className="space-y-3 px-3 py-3">
          <div className="flex justify-end">
            <div className="max-w-[85%] rounded-[10px] bg-[#0a84ff]/22 px-2.5 py-2 text-[12.5px] leading-snug text-white/95">
              What is this — can I stop it?
            </div>
          </div>
          <div className="flex justify-start">
            <div className="max-w-[92%] rounded-[10px] bg-white/[0.07] px-2.5 py-2 text-[12.5px] leading-snug text-white/90">
              <p>
                This is a <span className="font-medium text-white">Vite</span> dev
                server for <span className="font-mono text-[11px] text-teal-300">checkout-web</span>
                {" "}on port 5173. It&apos;s been up 2h 14m.
              </p>
              <p className="mt-2 text-white/70">
                Safe to stop — it&apos;s just a local frontend. Restart with{" "}
                <span className="font-mono text-[11px] text-white/85">npm run dev</span>.
              </p>
            </div>
          </div>
        </div>

        <div className="h-px bg-white/10" />
        <div className="flex items-center gap-2 px-3 py-2.5">
          <span className="flex-1 truncate text-[12px] text-white/30">
            Ask about this process…
          </span>
          <span className="flex h-[22px] w-[22px] items-center justify-center rounded-full bg-[#0a84ff] text-white">
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.8" strokeLinecap="round">
              <path d="M12 19V5" />
              <path d="M6 11l6-6 6 6" />
            </svg>
          </span>
        </div>
      </div>
    </div>
  );
}

function ShareTunnelMock() {
  return (
    <div className="relative mx-auto w-full max-w-[420px]">
      <div
        aria-hidden
        className="absolute -inset-8 -z-10 rounded-[45%] bg-[#f6821f]/25 blur-3xl"
      />

      {/* Bridge: localhost → live */}
      <div className="mb-4 flex items-center justify-center gap-3 text-[12px] font-medium">
        <span className="rounded-full border border-line bg-white/70 px-3 py-1 font-mono text-ink/70">
          localhost:5173
        </span>
        <span className="tunnel-flow flex items-center text-[#f6821f]" aria-hidden>
          <svg width="28" height="12" viewBox="0 0 28 12" fill="none">
            <path d="M1 6h22" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
            <path d="M19 2l5 4-5 4" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </span>
        <span className="inline-flex items-center gap-1.5 rounded-full bg-[#f6821f] px-3 py-1 text-white shadow-[0_8px_20px_-6px_rgba(246,130,31,0.65)]">
          <span className="relative flex h-1.5 w-1.5">
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-white/70" />
            <span className="relative inline-flex h-1.5 w-1.5 rounded-full bg-white" />
          </span>
          Live
        </span>
      </div>

      <div
        className="overflow-hidden rounded-[14px] border border-white/12 shadow-[0_28px_70px_rgba(8,10,16,0.5)]"
        style={{
          background: "linear-gradient(180deg, #2c2c2e 0%, #1c1c1e 100%)",
        }}
      >
        <div className="flex items-start justify-between px-3.5 pb-2.5 pt-3.5">
          <div>
            <p className="text-[14px] font-semibold text-white">Tunnels</p>
            <p className="mt-0.5 text-[10px] text-white/40">
              Cloudflare quick tunnels · public while active
            </p>
          </div>
          <span className="text-white/35">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
              <path d="M12 2a10 10 0 1 0 .001 20.001A10 10 0 0 0 12 2Zm3.54 12.46-1.08 1.08L12 13.08l-2.46 2.46-1.08-1.08L10.92 12 8.46 9.54l1.08-1.08L12 10.92l2.46-2.46 1.08 1.08L13.08 12l2.46 2.46Z" />
            </svg>
          </span>
        </div>
        <div className="h-px bg-white/10" />

        <div className="space-y-2.5 p-3">
          <div className="rounded-[10px] bg-white/[0.06] p-3 ring-1 ring-white/8">
            <div className="flex items-center gap-2">
              <span className="text-[13px] font-medium text-white">node</span>
              <span className="font-mono text-[11px] text-white/40">:5173</span>
              <span className="ml-auto inline-flex items-center gap-1 rounded-full bg-[#30d158]/18 px-2 py-0.5 text-[10px] font-semibold text-[#30d158]">
                <span className="h-1.5 w-1.5 rounded-full bg-[#30d158]" />
                Live
              </span>
            </div>
            <p className="mt-2 break-all font-mono text-[11px] leading-relaxed text-[#7dd3fc]">
              https://checkout-web-preview.trycloudflare.com
            </p>
            <div className="mt-3 flex gap-2">
              <span className="inline-flex h-8 flex-1 items-center justify-center rounded-[8px] bg-white/10 text-[12px] font-semibold text-white/90 ring-1 ring-white/12">
                Copy URL
              </span>
              <span className="inline-flex h-8 flex-1 items-center justify-center rounded-[8px] bg-[#c62828]/25 text-[12px] font-semibold text-[#ff8a80] ring-1 ring-[#c62828]/30">
                Stop
              </span>
            </div>
          </div>

          <div className="rounded-[10px] border border-dashed border-white/12 px-3 py-3 text-center text-[11px] text-white/35">
            Share any port from the ⋯ menu — one click.
          </div>
        </div>
      </div>
    </div>
  );
}

function PortsVisual() {
  const ports = [
    { port: "3000", tag: "next", ok: true },
    { port: "5173", tag: "vite", ok: true },
    { port: "8000", tag: "api", ok: true },
    { port: "8128", tag: "orphan", ok: false },
  ];
  return (
    <div className="flex flex-wrap gap-2">
      {ports.map((p) => (
        <div
          key={p.port}
          className="inline-flex items-center gap-2 rounded-[10px] border border-line bg-paper/80 px-3 py-2 shadow-sm"
        >
          <span
            className={`h-1.5 w-1.5 rounded-full ${p.ok ? "bg-[#30d158]" : "bg-[#ff9f0a]"}`}
          />
          <span className="font-mono text-[13px] font-medium tabular-nums text-ink">{p.port}</span>
          <span className="text-[11px] text-faint">{p.tag}</span>
        </div>
      ))}
    </div>
  );
}

function ActionsVisual() {
  const actions = [
    { label: "Stop", tone: "stop" },
    { label: "Force quit", tone: "force" },
    { label: "Open", tone: "open" },
  ];
  return (
    <div className="flex flex-wrap gap-2">
      {actions.map((a) => (
        <div
          key={a.label}
          className={`inline-flex h-10 items-center rounded-[10px] px-4 text-[13px] font-semibold tracking-[-0.01em] ${
            a.tone === "stop"
              ? "bg-ink text-paper"
              : a.tone === "force"
                ? "bg-[#c62828]/12 text-[#b71c1c] ring-1 ring-[#c62828]/20"
                : "bg-white/70 text-ink ring-1 ring-line"
          }`}
        >
          {a.label}
        </div>
      ))}
    </div>
  );
}

function Download() {
  return (
    <section id="download" className="border-t border-line">
      <Reveal className="mx-auto flex max-w-[1120px] flex-col items-center px-6 py-28 text-center md:px-10 md:py-36">
        <Image
          src="/brand/app-icon.png"
          alt=""
          width={112}
          height={112}
          className="mb-8 h-28 w-28"
        />
        <h2 className="font-display text-[clamp(1.9rem,3.5vw,2.8rem)] font-semibold tracking-[-0.04em] text-ink">
          Stop guessing what&apos;s listening.
        </h2>
        <p className="mt-4 max-w-md text-[1.05rem] font-light text-muted">
          Download Port Radar. Ask Apple Intelligence. Figure out your Mac.
        </p>
        <a
          href={site.downloadUrl}
          className="download-cta mt-9 inline-flex h-14 min-w-[16rem] items-center justify-center rounded-[16px] px-9 text-[16px] font-semibold"
        >
          <span>Download for macOS</span>
        </a>
        <p className="mt-4 text-[12px] font-light text-faint">
          macOS 14+ · Apple Silicon & Intel · Apple Intelligence on macOS 26+
        </p>
        <p className="mt-8 max-w-sm text-[12.5px] font-light leading-relaxed text-muted">
          <span className="font-medium text-ink">First launch:</span> macOS blocks apps that
          aren&apos;t notarized yet. Open System Settings → Privacy &amp; Security and click{" "}
          <span className="font-medium text-ink">Open Anyway</span>. Once only.
        </p>
        <div className="mt-8 flex flex-col items-center">
          <div className="flex flex-wrap items-center justify-center gap-3">
            <a
              href={site.githubUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex h-12 items-center gap-2.5 rounded-[14px] border border-line bg-white/70 px-6 text-[14.5px] font-semibold text-ink/80 transition-colors hover:border-ink/20 hover:bg-white hover:text-ink"
            >
              <GitHubIcon size={18} />
              View source on GitHub
            </a>
            <ProductHuntBadge />
          </div>
          <p className="mt-4 text-[12px] font-light text-faint">
            Open source under Apache 2.0
          </p>
        </div>
      </Reveal>
    </section>
  );
}

function Footer() {
  return (
    <footer className="border-t border-line">
      <div className="mx-auto flex max-w-[1120px] flex-col gap-6 px-6 py-8 sm:flex-row sm:items-center sm:justify-between md:px-10">
        <div className="flex items-center gap-2">
          <Image src="/brand/app-icon.png" alt="" width={32} height={32} className="h-8 w-8" />
          <span className="font-display text-[18px] font-semibold leading-none tracking-tight text-ink">
            Port Radar
          </span>
        </div>

        <div className="flex flex-col gap-2 sm:items-end">
          <div className="flex items-center gap-4 text-[12.5px] font-medium text-muted">
            <a
              href={site.githubUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center gap-1.5 transition-colors hover:text-ink"
            >
              <GitHubIcon size={15} />
              GitHub
            </a>
            <a
              href={`${site.githubUrl}/blob/main/LICENSE`}
              target="_blank"
              rel="noopener noreferrer"
              className="transition-colors hover:text-ink"
            >
              Apache 2.0
            </a>
            <a
              href={`${site.githubUrl}/releases/latest`}
              target="_blank"
              rel="noopener noreferrer"
              className="transition-colors hover:text-ink"
            >
              Releases
            </a>
            <a
              href={site.productHuntUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="transition-colors hover:text-ink"
            >
              Product Hunt
            </a>
          </div>
          <p className="text-[11px] font-light text-faint sm:text-right">
            Open source native macOS development utility.
          </p>
        </div>
      </div>
    </footer>
  );
}
