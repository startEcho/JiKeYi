const { nativeImage } = require('electron');
const fs = require('node:fs');
const path = require('node:path');

function createTrayIcon() {
  const iconPath = path.join(__dirname, 'assets', 'jikeyi-tray-template.svg');
  let svg = '';

  try {
    svg = fs.readFileSync(iconPath, 'utf8');
  } catch {
    svg = `
      <svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
        <path d="M14 16h36v8H36v24h-8V24H14z" fill="#ffffff"/>
        <circle cx="46" cy="46" r="6" fill="#ffffff"/>
      </svg>
    `.trim();
  }

  const image = nativeImage.createFromDataURL(
    `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`
  );
  image.setTemplateImage(true);

  return image.resize({
    width: 18,
    height: 18
  });
}

module.exports = {
  createTrayIcon
};
