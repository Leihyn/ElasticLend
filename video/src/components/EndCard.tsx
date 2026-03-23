import React from 'react';
import { useCurrentFrame, useVideoConfig, spring, Img, staticFile } from 'remotion';
import { COLORS } from '../constants';

export const EndCard: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const logoOpacity = spring({
    frame,
    fps,
    from: 0,
    to: 1,
    config: { damping: 30 },
  });

  const textOpacity = spring({
    frame: Math.max(0, frame - 10),
    fps,
    from: 0,
    to: 1,
    config: { damping: 30 },
  });

  const linksOpacity = spring({
    frame: Math.max(0, frame - 20),
    fps,
    from: 0,
    to: 1,
    config: { damping: 30 },
  });

  const ruleWidth = spring({
    frame,
    fps,
    from: 0,
    to: 120,
    config: { damping: 20 },
  });

  return (
    <div
      style={{
        width: '100%',
        height: '100%',
        background: COLORS.bg,
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 24,
      }}
    >
      <div style={{ opacity: logoOpacity }}>
        <Img src={staticFile('favicon.svg')} style={{ width: 80, height: 80 }} />
      </div>

      <div
        style={{
          fontFamily: "'Crimson Pro', Georgia, serif",
          fontSize: 56,
          fontWeight: 400,
          color: COLORS.text,
          opacity: logoOpacity,
        }}
      >
        <span style={{ color: COLORS.accent }}>Elastic</span>Lend
      </div>

      <div
        style={{
          width: ruleWidth,
          height: 1,
          background: COLORS.accent,
          marginTop: 8,
          marginBottom: 8,
        }}
      />

      <div
        style={{
          fontFamily: "'Source Serif 4', Georgia, serif",
          fontSize: 22,
          color: COLORS.textSecondary,
          opacity: textOpacity,
          textAlign: 'center' as const,
          maxWidth: 700,
          lineHeight: 1.6,
        }}
      >
        Portfolio-aware cross-chain lending backed by
        <br />
        IC3 research: Elastic Restaking Networks
      </div>

      <div
        style={{
          fontFamily: "'IBM Plex Mono', monospace",
          fontSize: 13,
          color: COLORS.textMuted,
          opacity: textOpacity,
          letterSpacing: '0.1em',
          marginTop: 8,
        }}
      >
        Bar-Zur & Eyal, ACM CCS 2025 | arXiv:2503.00170
      </div>

      <div
        style={{
          display: 'flex',
          gap: 40,
          marginTop: 32,
          opacity: linksOpacity,
        }}
      >
        {[
          'github.com/Leihyn/ElasticLend',
          'Shape Rotator Hackathon',
          'IC3 / FlashbotsX / Encode Club',
        ].map((link) => (
          <div
            key={link}
            style={{
              fontFamily: "'IBM Plex Mono', monospace",
              fontSize: 13,
              color: COLORS.textSecondary,
              letterSpacing: '0.05em',
            }}
          >
            {link}
          </div>
        ))}
      </div>
    </div>
  );
};
