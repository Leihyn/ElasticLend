import puppeteer from 'puppeteer-core';
import { fileURLToPath } from 'url';
import path from 'path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const chromePath = path.join(__dirname, '..', 'video', 'node_modules', '.remotion', 'chrome-headless-shell', 'mac-arm64', 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell');
const slidesPath = `file://${path.join(__dirname, 'deck.html')}`;
const outputPath = path.join(__dirname, 'ElasticLend-Slides.pdf');

async function generatePDF() {
  const browser = await puppeteer.launch({
    executablePath: chromePath,
    headless: true,
    args: ['--no-sandbox'],
  });

  const page = await browser.newPage();
  await page.setViewport({ width: 1920, height: 1080 });
  await page.goto(slidesPath, { waitUntil: 'networkidle0', timeout: 30000 });

  // Make all slides visible for PDF (override the display:none)
  await page.evaluate(() => {
    const slides = document.querySelectorAll('.slide');
    const navBar = document.querySelector('.nav-bar');
    if (navBar) navBar.style.display = 'none';

    document.querySelector('.deck').style.height = 'auto';
    document.querySelector('.deck').style.position = 'relative';

    slides.forEach(s => {
      s.style.display = 'flex';
      s.style.opacity = '1';
      s.style.position = 'relative';
      s.style.pageBreakAfter = 'always';
      s.style.minHeight = '100vh';
    });
  });

  await page.pdf({
    path: outputPath,
    width: '1920px',
    height: '1080px',
    printBackground: true,
    landscape: true,
  });

  await browser.close();
  console.log(`PDF saved to ${outputPath}`);
}

generatePDF().catch(console.error);
