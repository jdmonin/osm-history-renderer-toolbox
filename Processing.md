# Details of the Entire Process

Here is how to run the importing and rendering process.
You will run most of these commands inside the toolbox container.
Best practices and other improvements will be done as time permits.


## General Process

- Decide which local area you want to render history for, using the [OpenStreetMap](https://www.openstreetmap.org/) website
- Download history file for that area's surrounding region from the "internal" area of https://osm-internal.download.geofabrik.de/
- Extract the history of the local area you want to render, or its surrounding metropolitan area
- Import that extracted history into a PostGIS database
- Render the area at a single date
- Or, render a timespan of image "frames" and make them a video with a program like ffmpeg


## Building this image from Dockerfile

No special steps are needed here.
In the same directory as this project's Dockerfile, run:

`docker build -t osm-hist-renderer .`


## Notes when running this image

Before running the image, you'll want to make a local "datasets" directory
which will contain the downloaded `.osh.pbf` file.
At the end of the process, it will also contain the rendered `.png` images
and/or `.mp4` movies.

Currently, running this image just runs a bash shell inside its new container.
If you exit out of the container, you can just reattach with `docker start -ai [containername]` .

To work with OSM's large data files, you'll want to run it with a bind mount to `/datasets`.
So, the full command might be:

`docker run -it -v ~/datasets:/datasets osm-hist-renderer`

Depending on your preferences, you might also want to use a docker volume for the PostGIS database:

`docker run ... -v osm-hist-render-db:/var/lib/postgresql/12/main ...`

Alternately, let the DB live inside the container. You don't need the DB long term,
it can always be recreated by importing the extract history file again.


## Finding your Area and Bounding Box

Browse the map at https://www.openstreetmap.org/ and decide which specific area you want to
render the history of.

You'll need to make a note of its "Bounding Box" corners (west, south, east, north):

As you look around the map, your browser's address bar will update itself in this format:  
`https://www.openstreetmap.org/#map=15/43.0004/-78.7865`  
Those numbers are the zoom level, latitude, and longitude.

Find the corners of the area you want to render. Zoom into the corners as
precisely as you can, and note their latitude and longitude. Many commands here
will need a "bounding box" (`--bbox`) parameter, which is the four numbers for
west longitude, south latitude, east longitude, north latitude
separated by commas with no spaces:  
`--bbox -78.80725,42.99048,-78.77087,43.01311`


## Download regional history file

Browse by region for an `.osh.pbf` file in the "internal" area of
https://osm-internal.download.geofabrik.de/ (their "public downloads" don't have history files).

Be sure to get the `.osh.pbf` history file, not `.osm.pbf` current data.

Download into your local "datasets" directory, which is bind-mounted into the container.


## Extract the area history file from the region

**Note:** This step and all following ones run inside the container for simplicity.
That aspect will be improved later on.
See "Notes when running this image" section for a `docker run` command to launch the container.

Cut out (extract) a smaller area from the large regional file
to keep data volumes small and rendering fast.

For this step, you can either use the bounding box of the specific area
you want to render, or its metropolitan area (a few dozen km or miles across)
so you can then render other small areas within the same metro.

`osmium extract /datasets/your-region.osh.pbf -H --bbox -79.0778,42.6923,-78.5706,43.2030 --set-bounds -o /datasets/your-metro-area.osh.pbf`

Optionally, view statistics for the number of nodes and ways:

`osmium fileinfo -e /datasets/your-metro-area.osh.pbf`

The next step's import command will count up to those numbers as a progress indicator.


## Import that smaller history file into a PostGIS database

### Start postgres server

`service postgresql start`

### Create or reset the database

If this is your first time using this database, create it:

```
sudo -u postgres createuser renderer
echo "ALTER USER renderer PASSWORD 'renderer'" | sudo -u postgres psql
sudo -u postgres createdb -E UTF8 -O renderer gis
echo 'CREATE EXTENSION postgis; CREATE EXTENSION hstore; CREATE EXTENSION btree_gist; GRANT ALL ON geometry_columns TO renderer; GRANT ALL ON spatial_ref_sys TO renderer' | sudo -u postgres psql gis
```

Otherwise just empty the tables to reset it:

```
echo 'delete from hist_polygon; delete from hist_line; delete from hist_point;' | psql postgresql://renderer:renderer@localhost/gis 
```

### Import the history data

```
su - renderer
cd /build/osm-history-renderer/importer/
./osm-history-importer --dsn postgresql://renderer:renderer@localhost/gis /datasets/your-metro-area.osh.pbf
```


## Render the area at a single date

To render a single `png` image:

```
su - renderer
/build/osm-history-renderer/renderer/render.py --style /home/renderer/src/openstreetmap-carto/mapnik-hist.xml \
  --db postgresql://renderer:renderer@localhost/gis -x 1560x1200 --bbox -78.80725,42.99048,-78.77087,43.01311 \
  --date 2021-01-31 --file /datasets/yourarea-2021-01
```

This will output the area as it appeared on 2021-01-31 to `/datasets/yourarea-2021-01.png`.
The `-x` parameter sets the png's resolution.


## Render a timespan into a video

Note: Only one render can run at a time, because of how the renderer adds/drops
views in the database as it runs.

### Render the image frames

To render a timespan of image "frames" and make them a video with ffmpeg:

```
su - renderer
mkdir your-area-video && cd your-area-video
/build/osm-history-renderer/renderer/render-animation.py --style /home/renderer/src/openstreetmap-carto/mapnik-hist.xml \
  --db postgresql://renderer:renderer@localhost/gis -x 1560x1200 --bbox -78.80725,42.99048,-78.77087,43.01311 \
  --label "\n%Y-%m  " --label-gravity NorthEast
```

This will make an `animap` subdirectory and output each animation frame there,
numbered starting from `0000000000.png`.

The renderer defaults to starting just before the earliest data point in the area,
and stepping 1 month at a time to the present day. The `--label` is optional.
You can change the time step with an option like: `--anistep=months=+3` .  
For more options, run:  
`/build/osm-history-renderer/renderer/render-animation.py -h`

### Install ffmpeg

Because it adds dozens of packages and takes up several hundred MB of space,
ffmpeg is not included by default. Install it now:

```
apt update
apt install -y --no-install-recommends ffmpeg
```

### Create the video

ffmpeg with these flags will create a widely-compatible H264 MP4 video:

```
su - renderer
cd your-area-video
ffmpeg -framerate 8 -i animap/%010d.png \
  -vf minterpolate=fps=24:mi_mode=blend \
  -c:v libx264 -crf 8 -profile:v baseline -level 3.0 -pix_fmt yuv420p -movflags faststart \
  /datasets/your-area-h264.mp4
```

If you don't want the crossfade between rendered frames, omit this part:  
`-vf minterpolate=fps=24:mi_mode=blend`

For more info about ffmpeg flags, formats, and compatibility, see discussion at
https://superuser.com/questions/859010/what-ffmpeg-command-line-produces-video-more-compatible-across-all-devices


## Enjoy your creation!

That's the entire process.

If you want to render other places within the same extracted area, go ahead.
If you want to import and render a different area,
see above for how to "reset" the database first.


