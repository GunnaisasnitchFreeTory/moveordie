const fs = require('fs');
const j = JSON.parse(fs.readFileSync('C:/Users/david/.cursor/projects/c-Cursor-moveordie/agent-tools/93d28908-cf3e-4fd3-8ca5-d0a27fe6ef89.txt', 'utf8'));
let src = j.source;

// The old popup icon resolution block
const oldBlock = `\tlocal rewardType = result.rewardType or "Coins"
\tlocal popupIcon = ""
\tif rewardType == "Coins" then
\t\tpopupIcon = WHEEL_ICONS.Coins or ""
\telseif result.catalogId and WHEEL_ICONS[result.catalogId] then
\t\tpopupIcon = WHEEL_ICONS[result.catalogId]
\tend
\tlocal displayName = result.rewardName or "Reward"
\tlocal popupTitle = "YOU WON!"
\tif rewardType == "Coins" then
\t\tdisplayName = "+" .. tostring(result.coinsAwarded or 0) .. " Fate Coins"
\telseif rewardType == "Crown" and result.isDuplicate then
\t\tpopupTitle = "ALREADY OWNED!"
\t\tdisplayName = (result.rewardName or "Crown") .. "\\n+" .. tostring(result.coinsAwarded or 0) .. " Coins"
\tend`;

// The new popup icon resolution block with ItemCatalog crown lookup + wheelImage fallback
const newBlock = `\tlocal rewardType = result.rewardType or "Coins"
\tlocal popupIcon = ""
\tif rewardType == "Coins" then
\t\tpopupIcon = WHEEL_ICONS.Coins or ""
\telseif result.catalogId and WHEEL_ICONS[result.catalogId] then
\t\tpopupIcon = WHEEL_ICONS[result.catalogId]
\telseif rewardType == "Crown" and result.catalogId and ItemCatalog and ItemCatalog.Crowns then
\t\tlocal crownEntry = ItemCatalog.Crowns[result.catalogId]
\t\tif crownEntry and crownEntry.image and crownEntry.image ~= "" then
\t\t\tpopupIcon = crownEntry.image
\t\tend
\tend
\tif popupIcon == "" and result.wheelImage and result.wheelImage ~= "" then
\t\tpopupIcon = result.wheelImage
\tend
\tlocal displayName = result.rewardName or "Reward"
\tlocal popupTitle = "YOU WON!"
\tif rewardType == "Coins" then
\t\tdisplayName = "+" .. tostring(result.coinsAwarded or 0) .. " Fate Coins"
\telseif rewardType == "Crown" and result.isDuplicate then
\t\tpopupTitle = "ALREADY OWNED!"
\t\tdisplayName = (result.rewardName or "Crown") .. "\\n+" .. tostring(result.coinsAwarded or 0) .. " Coins"
\tend`;

if (src.includes(oldBlock)) {
    src = src.replace(oldBlock, newBlock);
    fs.writeFileSync('C:/Users/david/.cursor/projects/c-Cursor-moveordie/agent-tools/modified_spin_source.txt', src, 'utf8');
    console.log('SUCCESS: Replacement made. New line count: ' + src.split('\n').length);
} else {
    console.log('ERROR: Old block not found in source!');
    // Debug: show what the source looks like around line 1020
    const lines = src.split('\n');
    for (let i = 1018; i < 1036; i++) {
        console.log((i+1) + ': ' + JSON.stringify(lines[i]));
    }
}
