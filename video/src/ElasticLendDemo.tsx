import React from 'react';
import {
  useCurrentFrame,
  useVideoConfig,
  OffthreadVideo,
  staticFile,
  Series,
} from 'remotion';
import { loadFont } from '@remotion/google-fonts/CrimsonPro';
import { loadFont as loadBody } from '@remotion/google-fonts/SourceSerif4';
import { loadFont as loadMono } from '@remotion/google-fonts/IBMPlexMono';
import { TitleCard } from './components/TitleCard';
import { EndCard } from './components/EndCard';
import { CAPTIONS, COLORS, FPS } from './constants';

// Load only specific weights to reduce network requests
const { fontFamily: serifFont } = loadFont('normal', { subsets: ['latin'], weights: ['400', '600'] });
const { fontFamily: bodyFont } = loadBody('normal', { subsets: ['latin'], weights: ['400'] });
const { fontFamily: monoFont } = loadMono('normal', { subsets: ['latin'], weights: ['400'] });

const RECORDING_DURATION = 535;

// Simple caption overlay - no Sequence, just conditional render
const CaptionOverlay: React.FC<{ currentTime: number }> = ({ currentTime }) => {
  const activeCaption = CAPTIONS.find(
    (c) => currentTime >= c.start && currentTime < c.end
  );

  if (!activeCaption) return null;

  return (
    <div
      style={{
        position: 'absolute',
        bottom: 60,
        left: 80,
        right: 80,
        display: 'flex',
        justifyContent: 'center',
      }}
    >
      <div
        style={{
          background: 'rgba(10, 10, 10, 0.88)',
          borderLeft: `3px solid ${COLORS.accent}`,
          padding: '14px 24px',
          maxWidth: 1200,
          borderRadius: 3,
        }}
      >
        <span
          style={{
            fontFamily: bodyFont,
            fontSize: 26,
            lineHeight: 1.4,
            color: COLORS.text,
            letterSpacing: '0.01em',
          }}
        >
          {activeCaption.text}
        </span>
      </div>
    </div>
  );
};

// Screen recording with captions
const RecordingWithCaptions: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const currentTime = frame / fps;

  return (
    <div style={{ width: '100%', height: '100%', position: 'relative' }}>
      <OffthreadVideo
        src={staticFile('recording.mp4')}
        style={{ width: '100%', height: '100%', objectFit: 'cover' }}
      />
      <CaptionOverlay currentTime={currentTime} />
    </div>
  );
};

export const ElasticLendDemo: React.FC = () => {
  const { fps } = useVideoConfig();

  return (
    <div style={{ width: '100%', height: '100%', background: COLORS.bg }}>
      <Series>
        <Series.Sequence durationInFrames={3 * fps}>
          <TitleCard
            section="Shape Rotator Hackathon"
            title="Elastic Restaking Networks Applied to Lending"
            subtitle="DeFi, Security & Mechanism Design Track"
          />
        </Series.Sequence>

        <Series.Sequence durationInFrames={Math.floor(RECORDING_DURATION * fps)}>
          <RecordingWithCaptions />
        </Series.Sequence>

        <Series.Sequence durationInFrames={5 * fps}>
          <EndCard />
        </Series.Sequence>
      </Series>
    </div>
  );
};
