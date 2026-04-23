-- Sourceful Arc Transcriber DMG installer-window layout.
--
-- Called from `.github/workflows/release.yml` during the "Package .dmg"
-- step, with the volume name passed as an argument. Finder writes the
-- layout it applies here into the volume's .DS_Store, so any user who
-- mounts the published DMG sees the same window.
--
-- The arrow in the background image runs horizontally between the two
-- icon slots; icon positions below are aligned to the arrow endpoints
-- (app on the left at 128,260; Applications symlink on the right at
-- 388,260 inside a 640×400 window).

on run argv
    set volName to item 1 of argv

    tell application "Finder"
        tell disk volName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {400, 150, 1040, 550}

            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 128
            set background picture of viewOptions to file ".background:background.png"

            set position of item "Arc Transcriber.app" of container window to {128, 260}
            set position of item "Applications" of container window to {388, 260}

            update without registering applications
            delay 1
            close
        end tell
    end tell
end run
