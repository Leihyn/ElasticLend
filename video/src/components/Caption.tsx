import React from 'react';
import { useCurrentFrame, useVideoConfig, spring, interpolate } from 'remotion';
import { COLORS } from '../constants';

export const Caption: React.FC<{ text: string }> = ({ text }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const enterProgress = spring({
    frame,
    fps,
    from: 0,
    to: 1,
    config: { damping: 30 },
  });

  const opacity = interpolate(enterProgress, [0, 1], [0, 1]);
  const translateY = interpolate(enterProgress, [0, 1], [12, 0]);

  return (
    <div
      style={{
        position: 'absolute',
        bottom: 60,
        left: 80,
        right: 80,
        display: 'flex',
        justifyContent: 'center',
        opacity,
        transform: `translateY(${translateY}px)`,
      }}
    >
      <div
        style={{
          background: 'rgba(10, 10, 10, 0.9)',
          borderLeft: `3px solid ${COLORS.accent}`,
          padding: '14px 24px',
          maxWidth: 1200,
          borderRadius: 3,
        }}
      >
        <span
          style={{
            fontFamily: "'Source Serif 4', Georgia, serif",
            fontSize: 28,
            lineHeight: 1.4,
            color: COLORS.text,
            letterSpacing: '0.01em',
          }}
        >
          {text}
        </span>
      </div>
    </div>
  );
};
