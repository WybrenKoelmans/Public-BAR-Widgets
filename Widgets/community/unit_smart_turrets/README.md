# Smart Construction Turrets
This widget automatically tells your Construction Turrets what to help build, based on your energy and metal situation:

If your metal storage is above 10%, your Construction Turrets will help finish other Construction Turrets.
If your Converter Usage not at 100% , Construction Turrets will focus on building Energy Reactors/Wind/Solar.
If your Converter Usage stay at 100% for 5 seconds and Energy Storage is higher than 30%, Construction Turrets will focus on building Converters. 
You need to keep your Conversion Slider at the minimum for this to work.
It checks all your Construction Turrets and finds the best thing for each one to assist, so you don’t have to babysit them.

Why use it?

Keeps your nanos busy and productive, instead of standing around.
Helps avoid energy stalls and wasted metal.
Lets you focus on the bigger picture, not base micro.
Super useful in big games or when you’re juggling lots of bases.
Give it a try and let me know what you think! Feedback and suggestions welcome.

If you want you adjust Converter Stable time or Energy Threshold, look for these lines:
           local CONVERTER_STABLE_TIME = 5 -- seconds of stable 100% usage to switch to converters
           local ENERGY_STORAGE_THRESHOLD = 30 -- percent energy storage to consider converters stable
