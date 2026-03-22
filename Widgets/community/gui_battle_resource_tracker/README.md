# Battle Resource Tracker (see metal exchanged during combat)

Shows the difference in metal lost between your allyteam and your opponents around a location on the game map. When a unit dies, it will add the metal difference to a nearby marker if one exists. If no units have died in a location for a while, the marker will disappear.

The result is that you can get an idea of how well your team is doing in an area of the map, or how effective your raid was, or if your bombing run was worth it.

So, for example, if you killed 3 of your opponents that cost 100 metal each, and you lost 4 units that cost 40 metal each, it would show "+140m" around where those units died, for a short while. If you lost another unit that costs 500 metal nearby, it would become "-360m".

Check the beginning of the file for configuration variables.
Check the settings window for configuration.

Notes:
This can only track units destroyed in areas you can see. For spectators, this is everything. For players, this means that your won't see how much your lolcannon is destroying unless you have LOS there.
The text is displayed under unit icons. This makes it a little harder to read when zoomed out. I'm not sure how to change that. fixed in version 2
Reclaim isn't considered, so a battle that looks favorable for one side through this widget might go the other way once wrecks are reclaimed or resurrected.
I didn't notice any performance issues on my computer, but there are definitely optimizations that could be made.
This only tracks metal. Other resources could be included, but metal is by far the most important in most cases, so I'm not sure it's worth adding more information to the markers.
