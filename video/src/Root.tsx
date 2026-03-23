import React from 'react';
import { Composition } from 'remotion';
import { ElasticLendDemo } from './ElasticLendDemo';
import { FPS, WIDTH, HEIGHT } from './constants';

const RECORDING_DURATION = 535; // seconds
const TITLE_DURATION = 3;
const END_DURATION = 5;
const TOTAL_DURATION = TITLE_DURATION + RECORDING_DURATION + END_DURATION;

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="ElasticLendDemo"
        component={ElasticLendDemo}
        durationInFrames={Math.ceil(TOTAL_DURATION * FPS)}
        fps={FPS}
        width={WIDTH}
        height={HEIGHT}
      />
    </>
  );
};
