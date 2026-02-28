const fs = require('fs');
const file = 'C:/Cursor/moveordie/src/client/UI/HUDPanel.luau';
let src = fs.readFileSync(file, 'utf8');

const oldStr = '\t\t\tafkIcon.Text = ""';
const newStr = '\t\t\tafkIcon.Text = isAFK and "\uD83C\uDFC3" or "\uD83D\uDCA4"';

if (src.includes(oldStr)) {
    src = src.replace(oldStr, newStr);
    fs.writeFileSync(file, src, 'utf8');
    console.log('SUCCESS: afkIcon emoji restored');
} else {
    console.log('ERROR: pattern not found');
    const idx = src.indexOf('afkIcon.Text');
    console.log('Context:', JSON.stringify(src.slice(idx - 3, idx + 30)));
}
