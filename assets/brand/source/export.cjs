#!/usr/bin/env node
// Run with sharp available to Node; see ../README.md.
const fs = require('node:fs');
const path = require('node:path');
const sharp = require('sharp');
const design = require('./lettering.json');
const palettes = require('./palettes.json');
const out = path.resolve(__dirname, '..');
const { amber, charcoal, paper } = design.colours;
const basePalette = palettes.find(palette => palette.id === design.basePalette);
if (!basePalette) throw new Error(`Unknown base palette: ${design.basePalette}`);
const { onLight: primaryLight, onDark: primaryDark } = basePalette;
fs.mkdirSync(path.join(out, 'svg'), { recursive: true });
fs.mkdirSync(path.join(out, 'png'), { recursive: true });

function word(colour) {
  let x = 0;
  const paths = [...design.word].map((letter, index) => {
    const glyph = design.glyphs[letter];
    const result = `<path data-letter="${letter}" transform="translate(${x} 0)" fill="${colour}" fill-rule="evenodd" d="${glyph.path}"/>`;
    x += glyph.width;
    if (index < design.word.length - 1) x += design.gapAfter[letter] ?? design.gap;
    return result;
  });
  return { width: x, paths: paths.join('\n') };
}

function svg(width, height, title, description, content) {
  return `<?xml version="1.0" encoding="UTF-8"?>\n<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-labelledby="title desc">\n<title id="title">${title}</title>\n<desc id="desc">${description}</desc>\n${content}\n</svg>\n`;
}

function mark(colour) {
  return `<path fill="${colour}" transform="translate(16 10)" d="${design.glyphs.S.path}"/>`;
}

function tile(x, y, width, height, cut, colour) {
  return `<path fill="${colour}" d="M${x+cut} ${y}H${x+width}V${y+height-cut}L${x+width-cut} ${y+height}H${x}V${y+cut}Z"/>`;
}

function icon(isFavicon = false, colour = primaryDark) {
  const body = isFavicon ? mark(colour) : `<g transform="translate(12 12) scale(.75)">${mark(colour)}</g>`;
  return tile(0, 0, 96, 96, isFavicon ? 12 : 16, charcoal) + body;
}

function saveSvg(name, content, directory = out) {
  fs.writeFileSync(path.join(directory, 'svg', `${name}.svg`), content);
}

const wordWidth = word(charcoal).width;
const logoWidth = wordWidth + design.padding * 2;
const logoHeight = design.height + design.padding * 2;
const logoDescription = 'Sensible in custom angular lettering. The Folded S is the first letter of the word.';
const logo = colour => svg(logoWidth, logoHeight, 'Sensible', logoDescription,
  `<g transform="translate(${design.padding} ${design.padding})">${word(colour).paths}</g>`);

for (const [name, colour] of Object.entries({light:primaryLight, dark:primaryDark, black:'#000000', white:'#ffffff'})) {
  saveSvg(`sensible-logo-${name}`, logo(colour));
}
saveSvg('sensible-wordmark', logo(primaryLight));
for (const [name, colour] of Object.entries({light:primaryLight, dark:primaryDark, amber, charcoal, black:'#000000', white:'#ffffff'})) {
  saveSvg(`sensible-mark-${name}`, svg(96, 96, 'Sensible', 'Standalone Folded S initial.', mark(colour)));
}
saveSvg('sensible-icon', svg(96, 96, 'Sensible', 'Folded S on a charcoal tile with matching clipped corners.', icon()));
saveSvg('sensible-favicon', svg(96, 96, 'Sensible', 'Folded S on a charcoal tile, inset for small sizes.', icon(true)));

// The sheet shares production paths; only its captions use text.
const label = (x,y,content,colour='#62675f') => `<text x="${x}" y="${y}" font-family="Arial, sans-serif" font-size="18" fill="${colour}">${content}</text>`;
const placedWord = (x,y,scale,colour) => `<g transform="translate(${x} ${y}) scale(${scale})">${word(colour).paths}</g>`;
const overview = svg(1440, 1050, 'Sensible — custom Folded S wordmark',
  'One continuous wordmark with matching angular lettering, shown in teal on light and dark backgrounds, and monochrome, with the standalone initial.', `
<rect width="1440" height="1050" fill="${paper}"/>
${label(72,68,'SENSIBLE / CUSTOM LETTERING')}
${placedWord(72,144,1296/wordWidth,primaryLight)}
${label(72,409,'ONE WORD · THE FOLDED S IS THE INITIAL')}
${tile(48,456,1344,294,24,charcoal)}
${placedWord((1440-wordWidth*1.9)/2,525,1.9,primaryDark)}
${label(80,717,`ON DARK / ${basePalette.name.toUpperCase()}`, '#bdc4b8')}
${label(72,815,'MONOCHROME')}
${placedWord(72,852,.9,'#000000')}
${label(640,815,'STANDALONE INITIAL')}
<g transform="translate(635 842) scale(1.05)">${mark(primaryLight)}</g>
<g transform="translate(808 852) scale(.85)">${icon()}</g>
<g transform="translate(958 868) scale(.5)">${icon()}</g>
<g transform="translate(1090 876) scale(.3333333333)">${icon(true)}</g>
${label(72,1001,'Custom vector lettering · no font dependency')}
${label(1110,1001,'A Korq project')}`);
fs.writeFileSync(path.join(out,'sensible-brand-overview.svg'),overview);

const comparison = svg(1440, 1040, 'Sensible — colour options',
  'Four colour options for the same custom wordmark: teal, cobalt, violet and raspberry. Each is shown on light and dark backgrounds.', `
<rect width="1440" height="1040" fill="${paper}"/>
${label(48,55,'SENSIBLE / COLOUR OPTIONS')}
${palettes.map((palette,index) => {
  const x = 48 + (index % 2) * 704;
  const y = 108 + Math.floor(index / 2) * 432;
  return `
${label(x,y,`${String(index+1).padStart(2,'0')} · ${palette.name.toUpperCase()}`,charcoal)}
${label(x+500,y,palette.onLight.toUpperCase())}
${placedWord(x+20,y+49,616/wordWidth,palette.onLight)}
${tile(x,y+182,656,176,20,charcoal)}
${placedWord(x+20,y+216,616/wordWidth,palette.onDark)}
${label(x+22,y+336,palette.onDark.toUpperCase(),'#bdc4b8')}`;
}).join('\n')}
${label(48,1000,'Same wordmark · light and dark variants')}
${label(1210,1000,'A Korq project')}`);
fs.writeFileSync(path.join(out,'sensible-colour-options.svg'),comparison);

function faviconBuffer(images, sizes) {
  const header = Buffer.alloc(6+16*sizes.length);
  header.writeUInt16LE(1,2);
  header.writeUInt16LE(sizes.length,4);
  let offset = header.length;
  sizes.forEach((size,index) => {
    const at = 6+16*index;
    header[at] = header[at+1] = size;
    header.writeUInt16LE(1,at+4);
    header.writeUInt16LE(32,at+6);
    header.writeUInt32LE(images[index].length,at+8);
    header.writeUInt32LE(offset,at+12);
    offset += images[index].length;
  });
  return Buffer.concat([header,...images]);
}

async function exportPalette(palette) {
  const directory = path.join(out, 'palettes', palette.id);
  fs.mkdirSync(path.join(directory,'svg'), {recursive:true});
  fs.mkdirSync(path.join(directory,'png'), {recursive:true});
  for (const [variant, colour] of [['light',palette.onLight],['dark',palette.onDark]]) {
    saveSvg(`sensible-logo-${variant}`,logo(colour),directory);
    saveSvg(`sensible-mark-${variant}`,svg(96,96,'Sensible',`Folded S in ${palette.name.toLowerCase()} for ${variant} backgrounds.`,mark(colour)),directory);
    await sharp(Buffer.from(logo(colour)),{density:288}).resize({width:1600}).png().toFile(path.join(directory,'png',`sensible-logo-${variant}.png`));
    await sharp(path.join(directory,'svg',`sensible-mark-${variant}.svg`),{density:384}).resize(512,512).png().toFile(path.join(directory,'png',`sensible-mark-${variant}.png`));
  }
  saveSvg('sensible-icon',svg(96,96,'Sensible',`${palette.name} Folded S on a charcoal tile.`,icon(false,palette.onDark)),directory);
  saveSvg('sensible-favicon',svg(96,96,'Sensible',`${palette.name} Folded S favicon.`,icon(true,palette.onDark)),directory);
  await sharp(path.join(directory,'svg','sensible-icon.svg'),{density:384}).resize(512,512).png().toFile(path.join(directory,'png','sensible-icon-512.png'));
  const sizes = [16,32,48];
  const images = [];
  for (const size of sizes) {
    const png = await sharp(path.join(directory,'svg','sensible-favicon.svg'),{density:384}).resize(size,size).png().toBuffer();
    fs.writeFileSync(path.join(directory,'png',`sensible-favicon-${size}.png`),png);
    images.push(png);
  }
  fs.writeFileSync(path.join(directory,'favicon.ico'),faviconBuffer(images,sizes));
}

async function main() {
  for (const name of ['light','dark','black','white']) {
    await sharp(path.join(out,'svg',`sensible-logo-${name}.svg`), {density:288}).resize({width:1600}).png().toFile(path.join(out,'png',`sensible-logo-${name}.png`));
  }
  for (const name of ['light','dark','amber','charcoal']) {
    await sharp(path.join(out,'svg',`sensible-mark-${name}.svg`), {density:384}).resize(512,512).png().toFile(path.join(out,'png',`sensible-mark-${name}.png`));
  }
  for (const size of [180,192,512]) {
    await sharp(path.join(out,'svg','sensible-icon.svg'), {density:384}).resize(size,size).png().toFile(path.join(out,'png',`sensible-icon-${size}.png`));
  }
  const sizes = [16,32,48];
  const images = [];
  for (const size of sizes) {
    const png = await sharp(path.join(out,'svg','sensible-favicon.svg'), {density:384}).resize(size,size).png().toBuffer();
    fs.writeFileSync(path.join(out,'png',`sensible-favicon-${size}.png`),png);
    images.push(png);
  }
  fs.writeFileSync(path.join(out,'favicon.ico'),faviconBuffer(images,sizes));
  await sharp(Buffer.from(overview)).png().toFile(path.join(out,'sensible-brand-overview.png'));
  for (const palette of palettes) await exportPalette(palette);
  await sharp(Buffer.from(comparison)).png().toFile(path.join(out,'sensible-colour-options.png'));
  // Keep the manual self-contained in both the repository and the offline ISO.
  const manualAssets = path.resolve(out,'../../manual/assets');
  fs.mkdirSync(manualAssets,{recursive:true});
  for (const name of ['sensible-logo-light.svg','sensible-logo-dark.svg','sensible-favicon.svg']) {
    fs.copyFileSync(path.join(out,'svg',name),path.join(manualAssets,name));
  }
  console.log(`Exported custom ${design.word} wordmark (${logoWidth} × ${logoHeight}), symbols, icons, PNGs and ${palettes.length} colour options.`);
}

main().catch(error => { console.error(error); process.exitCode=1; });
