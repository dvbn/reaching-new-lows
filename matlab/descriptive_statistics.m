project_root = setup_paths;
% Dropbox directory
dir_dropbox = project_root;


% Create STRUCT with weather observations (by station)
WEATHER_LIST = dir('../data/weather-station-*');
time_range_weather = timerange("2015-01-01","2021-03-01");
for station=1:length(WEATHER_LIST)
    % Create station specific timetable for weather observations
    station_name = WEATHER_LIST(station).name(end-7:end-4);
    station_filename = fullfile(WEATHER_LIST(station).folder, WEATHER_LIST(station).name);
    WEATHER.(station_name) = readtimetable(station_filename);

    % Balance timetable
    WEATHER.(station_name) = WEATHER.(station_name)(time_range_weather,:);
end

% Initialize table and prepare format
tableID = fopen(fullfile(dir_dropbox,'tables','table_descriptive_stats_weather.tex'), 'w');
fmtCell{1} = ' %3.1f & (%3.1f) & %3.1f & (%3.1f) & %3.1f & (%3.1f) &';
fmtCell{2} = ' %3.1f & (%3.1f) & %3.1f & (%3.1f) & %3.1f & (%3.1f) &';
fmtCell{3} = ' %3.0f & (%2.0f) ';
fmt = sprintf('%s & %s \\\\\\\\\n', '%10s', horzcat(fmtCell{:}));

% Print table
station_name = fieldnames(WEATHER);
descriptive_stats = zeros(14,1);
for s=1:length(station_name)

    descriptive_stats(1) = mean(WEATHER.(station_name{s}).temperature);
    descriptive_stats(2) = std(WEATHER.(station_name{s}).temperature);
    descriptive_stats(3) = mean(WEATHER.(station_name{s}).humidity);
    descriptive_stats(4) = std(WEATHER.(station_name{s}).humidity);
    descriptive_stats(5) = mean(WEATHER.(station_name{s}).pressure);
    descriptive_stats(6) = std(WEATHER.(station_name{s}).pressure);

    descriptive_stats(7) = mean(WEATHER.(station_name{s}).precipitation*1000);
    descriptive_stats(8) = std(WEATHER.(station_name{s}).precipitation*1000);
    descriptive_stats(9) = mean(WEATHER.(station_name{s}).windSpeed);
    descriptive_stats(10) = std(WEATHER.(station_name{s}).windSpeed);

    % Get wind gust and convert wind angle in Cartesian coordinate
    wind_gust = WEATHER.(station_name{s}).windGust;
    wind_cos = cos(WEATHER.(station_name{s}).windAngle);
    wind_sin = sin(WEATHER.(station_name{s}).windAngle);

    % Compute mean and std for "positive" wind gust 
    descriptive_stats(11) = mean(wind_gust(wind_gust > 0));
    descriptive_stats(12) = std(wind_gust(wind_gust > 0));

    % Compute "circular" mean and std 
    descriptive_stats(13) = mod((180/pi) * atan2(mean(wind_sin), mean(wind_cos)), 360);
    descriptive_stats(14) = (180/pi) * atan2(std(wind_sin), std(wind_cos));

    % Print descriptive statistics
    fprintf(tableID, fmt, upper(station_name{s}), descriptive_stats);
end
fclose(tableID);


