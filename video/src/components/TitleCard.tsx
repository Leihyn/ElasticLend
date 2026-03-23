import React from 'react';
import { useCurrentFrame, useVideoConfig, spring, interpolate } from 'remotion';
import { COLORS } from '../constants';

export const TitleCard: React.FC<{
  section: string;
  title: string;
  subtitle?: string;
}> = ({ section, title, subtitle }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const ruleWidth = spring({
    frame,
    fps,
    from: 0,
    to: 60,
    config: { damping: 20 },
  });

  const textOpacity = spring({
    frame: Math.max(0, frame - 8),
    fps,
    from: 0,
    to: 1,
    config: { damping: 30 },
  });

  const subtitleOpacity = spring({
    frame: Math.max(0, frame - 16),
    fps,
    from: 0,
    to: 1,
    config: { damping: 30 },
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
        gap: 20,
      }}
    >
      <div
        style={{
          width: ruleWidth,
          height: 2,
          background: COLORS.accent,
        }}
      />
      <div
        style={{
          fontFamily: "'IBM Plex Mono', monospace",
          fontSize: 14,
          letterSpacing: '0.2em',
          textTransform: 'uppercase' as const,
          color: COLORS.accent,
          opacity: textOpacity,
        }}
      >
        {section}
      </div>
      <div
        style={{
          fontFamily: "'Crimson Pro', Georgia, serif",
          fontSize: 52,
          fontWeight: 400,
          color: COLORS.text,
          opacity: textOpacity,
          textAlign: 'center' as const,
          maxWidth: 900,
          lineHeight: 1.2,
        }}
      >
        {title}
      </div>
      {subtitle && (
        <div
          style={{
            fontFamily: "'Source Serif 4', Georgia, serif",
            fontSize: 22,
            color: COLORS.textSecondary,
            opacity: subtitleOpacity,
            textAlign: 'center' as const,
            maxWidth: 700,
            marginTop: 8,
          }}
        >
          {subtitle}
        </div>
      )}
    </div>
  );
};
