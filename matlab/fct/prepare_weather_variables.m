function X_weather = prepare_weather_variables(X_time)

    % Read weather station filenames (timetable)
    filename = '../data/weather-station-*.csv';
    weather = dir(filename);

    % Smoothing
    smoothing_window = 24 * 1;

    % Set size
    nObs = length(X_time);
    nStation = length(weather);

    % Prepare weather covariates
    X_weather = zeros(nObs, nStation, 8);
    X_weather_pca = cell(3,1);
    for s=1:nStation
        % Read observations
        TT = readtimetable(fullfile(weather(s).folder,weather(s).name));
        TT = TT(TT.Time >= X_time(1) & TT.Time <= X_time(end),:);

        % Reshape wind data (angle-speed-gust)
        wind_x = cos((180/pi) * TT.windAngle);
        wind_y = sin((180/pi) * TT.windAngle);
        wind_s = rescale(movavg(TT.windSpeed, 'exponential', smoothing_window));
        wind_g = rescale(movavg(TT.windGust, 'exponential', smoothing_window));

        % Pack smoothed and rescaled weather data 
        X_weather(:,s,1) = movavg(TT.temperature, 'exponential', smoothing_window);
        X_weather(:,s,2) = movavg(TT.humidity, 'exponential', smoothing_window);
        X_weather(:,s,3) = movavg(TT.pressure, 'exponential', smoothing_window);
        X_weather(:,s,4) = rescale(TT.precipitation, -1, 1);
        X_weather(:,s,5) = wind_s .* wind_x;
        X_weather(:,s,6) = wind_s .* wind_y;
        X_weather(:,s,7) = wind_g .* wind_x;
        X_weather(:,s,8) = wind_g .* wind_y;
    end

    % PCA for temperature-humidity-pressure
    for i=1:3
        [~, score, ~, ~, explained] = pca(X_weather(:,:,i));
        nComponent = find(cumsum(explained) > 95,1);
        X_weather_pca{i} = zeros(nObs,nComponent);
        for j=1:nComponent
            X_weather_pca{i}(:,j) = rescale(score(:,j),-1,1);
        end
    end

    % Reshape weather variables in rectangular matrix
    X_weather_pca = horzcat(X_weather_pca{:});
    X_weather = [X_weather_pca reshape(X_weather(:,:,4:end), nObs, [])];

end
