function X_datetime = prepare_datetime_variables(X_time)

    % Prepare covariates for trend, diurnal pattern and seasonality
    X_trend = rescale((0:length(X_time)-1)');
    X_wday = dummyvar(weekday(X_time));
    X_day = [sin(2*pi/24 * hour(X_time)) cos(2*pi/24 * hour(X_time))];
    X_day = [X_day [sin(4*pi/24 * hour(X_time)) cos(4*pi/24 * hour(X_time))]];
    X_day = [X_day [sin(6*pi/24 * hour(X_time)) cos(6*pi/24 * hour(X_time))]];
    X_week = [sin(2*pi/53 * week(X_time)) cos(2*pi/53 * week(X_time))];
    X_week = [X_week [sin(4*pi/53 * week(X_time)) cos(4*pi/53 * week(X_time))]];
    X_week = [X_week [sin(6*pi/53 * week(X_time)) cos(6*pi/53 * week(X_time))]];

    % Pack covariates
    X_datetime = [X_trend X_wday X_day X_week];

end
