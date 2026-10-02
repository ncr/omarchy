# Backgrounds

Every theme ships with its own set of backgrounds, and you can add extras of your own in `~/.config/omarchy/backgrounds/[theme]`. If you want to add an extra background image to, say, the nord theme, you just put the file in `~/.config/omarchy/backgrounds/nord`.

You can do this most easily by going to _Install > Style > Background_ in the Omarchy Menu. That'll bring up the folder where the backgrounds for that theme is stored. Hit `Super + Shift + F` to start another file manager, find your background, copy it over.  Now it'll be included in the choices of backgrounds you can select between using `Super + Ctrl + Space`.

Backgrounds can be videos as well as stills. Drop an `mp4`, `m4v`, `mov`, `webm`, `mkv`, or `avi` file in the same folder and it appears alongside the images. Videos are played by the OWE wallpaper engine. It decodes the video once for all monitors and plays its sound through the default audio output, and it stops playback whenever nothing can see it. The lock screen draws the same decode, muted, through OWE. A video wallpaper still costs far more power than a still one.

Each monitor can also show a background of its own, which helps when the screens have different shapes, like a laptop next to an ultrawide. `omarchy theme bg set --monitor DP-1 ~/Pictures/ultrawide.png` keeps that image on DP-1 while the other monitors follow the theme. Point it at a folder instead, and DP-1 shows the file in that folder that has the same name as the current background, or the shared background when there is none, so cycling backgrounds and switching themes keep working. `omarchy theme bg set --monitor DP-1 --clear` puts DP-1 back on the shared background. The monitor names are the ones `hyprctl monitors` shows. Videos always play on every monitor.

You can find a huge collection of cool curated backgrounds on https://github.com/dharmx/walls.

Video backgrounds keep a cached still on the lock screen while playback is paused or unavailable. Animated GIFs play on the desktop and show a still frame on the lock screen.
