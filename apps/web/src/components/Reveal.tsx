"use client";

import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { usePrefersReducedMotion } from "@/lib/reducedMotion";

type RevealProps = {
  children: ReactNode;
  className?: string;
  /** Stagger delay in ms once visible */
  delay?: number;
};

/** Subtle fade + rise when scrolled into view. */
export function Reveal({ children, className = "", delay = 0 }: RevealProps) {
  const ref = useRef<HTMLDivElement>(null);
  const reduced = usePrefersReducedMotion();
  const [seen, setSeen] = useState(false);
  const shown = reduced || seen;

  useEffect(() => {
    const el = ref.current;
    if (!el || reduced) return;

    const io = new IntersectionObserver(
      ([entry]) => {
        if (entry?.isIntersecting) {
          setSeen(true);
          io.disconnect();
        }
      },
      { threshold: 0.14, rootMargin: "0px 0px -8% 0px" },
    );

    io.observe(el);
    return () => io.disconnect();
  }, [reduced]);

  const style: CSSProperties | undefined = delay
    ? { transitionDelay: `${delay}ms` }
    : undefined;

  return (
    <div
      ref={ref}
      className={`reveal ${shown ? "reveal-in" : ""} ${className}`.trim()}
      style={style}
    >
      {children}
    </div>
  );
}
