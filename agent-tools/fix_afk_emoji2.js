const fs = require('fs');
const file = 'C:/Cursor/moveordie/src/client/UI/HUDPanel.luau';
let src = fs.readFileSync(file, 'utf8');

const oldStr = '\t\t\tafkIcon.Text = ""';

console.log('File length:', src.length);
console.log('Contains pattern:', src.includes(oldStr));

// 🏃 = U+1F3C3 = \uD83C\uDFC3  |  💤 = U+1F4A4 = \uD83D\uDCA4
const running = '\uD83C\uDFC3';
const zzz = '\uD83D\uDCA4';
const newStr = '\t\t\tafkIcon.Text = isAFK and "' + running + '" or "' + zzz + '"';

src = src.replace(oldStr, newStr);
fs.writeFileSync(file, src, 'utf8');

// Verify immediately
const verify = fs.readFileSync(file, 'utf8');
const idx = verify.indexOf('afkIcon.Text');
console.log('After write:', JSON.stringify(verify.slice(idx, idx + 60)));
