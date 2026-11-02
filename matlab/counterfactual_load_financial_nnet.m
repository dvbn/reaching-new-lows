project_root = setup_paths;
% File: counterfactual_load_financial.m
%
% Input:
%   (a)
% Output:
%   (a)
%   (b)
% 
% Author:
% Date:


% Clear workspace
clearvars;
project_root = setup_paths;
clc;

% Set path
addpath('fct')
addpath('../data')

% Dropbox directory
DIR = project_root;

% Set seed 
rng(123)

% Training/nnet parameters
nCrossFit = 5;
rtest = 0.15;
nneurons = 10;

% Sample period: February 1st, 2005 to January 4th, 2021
date_start = datetime(2005,02,01);
date_pred = datetime(2008,09,01);
date_end = datetime(2009,03,01);
year_index_loss = 2007;

% Filenames to store results
log_forecast = fullfile(DIR, 'log_forecast_financial');
dir_error = fullfile(DIR, 'figures', 'nnet', 'financial', sprintf('error_%d_neurons', nneurons));

% Create folder to store nnet error distributions
if( ~exist(dir_error, 'dir') )
    mkdir(dir_error)
end

% ----------------------------------------------------------------------------------------------- %
%%   Prepare data: Read LOAD, FLOAD and WEATHER data                                              %
% ----------------------------------------------------------------------------------------------- %

% Read actual load and forecast load (NYISO)
LOAD = readtimetable('load-realized.csv');
FLOAD = readtimetable('load-forecasted.csv');

% Get list of zone
ZONE_LIST = LOAD.Properties.VariableNames;

% Read realized and forecasted load matrices and set datetime vector
index = LOAD.Time >= date_start & LOAD.Time < date_end;
X_time = LOAD.Time(index);
Y_hat = zeros(length(X_time),length(ZONE_LIST));
Y_load = zeros(length(X_time),length(ZONE_LIST));
Y_fload = zeros(length(X_time),length(ZONE_LIST));
lossfactor = zeros(length(ZONE_LIST),1);
index_loss = year(X_time) <= year_index_loss;
for zone=1:length(ZONE_LIST)
    % Read realized and forecasted load
    Y_load(:,zone) = LOAD.(ZONE_LIST{zone})(index);
    Y_fload(:,zone) = FLOAD.(ZONE_LIST{zone})(index);

    % Adjust NYISO forecast to include losses (compute loss factor)
    loss_forecast = Y_fload(index_loss,zone) - Y_load(index_loss,zone);
    lossfactor(zone) = mean(loss_forecast ./ Y_fload(index_loss,zone));
    Y_fload(:,zone) = Y_fload(:,zone) * (1-lossfactor(zone));
end

% Prepare covariates
X_datetime = prepare_datetime_variables(X_time);
X_weather = prepare_weather_variables(X_time);

% Set matrix of predictors
X = [X_datetime X_weather];

% ----------------------------------------------------------------------------------------------- %
%%  Prepare Train-Validation-Test                                                                 %
% ----------------------------------------------------------------------------------------------- %

% Read holidays list
HOLIDAYS = readtable('holidays.csv');

% Set day index
day_index = unique(X_time - timeofday(X_time));
holidays_index = zeros(length(day_index),1);
for i=1:height(HOLIDAYS)
    holidays_index(day_index == HOLIDAYS.date(i)) = HOLIDAYS.index(i);
end

% Set prediction set
predInd = find(X_time >= date_pred & X_time < date_end)';

% Set Train-Validation set (cross-fitting) 
ndays = days(date_pred - date_start);
C_holdout = cvpartition(ndays, 'HoldOut', rtest);
C_crossval = cvpartition(C_holdout.TrainSize, 'KFold', nCrossFit);

% Set Testing set
testDay = setdiff(find(C_holdout.test), holidays_index);
testInd = reshape(((testDay-1)*24+(1:24))',[],1);

% Initialize cellArray for Cross-Fitting split
trainInd = cell(nCrossFit,1);
valInd = cell(nCrossFit,1);

% Set Train-Validation sets
day_train_index = find(C_holdout.training);
for k=1:nCrossFit
    % Remove holidays from Train-Validation split
    trainDay = setdiff(day_train_index(C_crossval.training(k)), holidays_index);
    valDay = setdiff(day_train_index(C_crossval.test(k)), holidays_index);
    
    % Reshape day index to hourly index
    trainInd{k} = reshape(((trainDay-1)*24+(1:24))',[],1);
    valInd{k} = reshape(((valDay-1)*24+(1:24))',[],1);
end

% For comparing error distribution
crossFitInd = setdiff(find(X_time < date_pred), testInd);

% ----------------------------------------------------------------------------------------------- %
%%  Train Neural Network for counterfactual prediction                                            %
% ----------------------------------------------------------------------------------------------- %

% Prepare file to print result
fileID = fopen(sprintf('%s_%d_neurons', log_forecast, nneurons),'w');
fmt = '%10s \t\t %1.5f  %1.5f \t %1.5f  %1.5f \t\t %-4.2f \t\t %1.5f \t %1.5f \n';

% Initialize color matrix
color_matrix = linspecer(2);

% Get zone full name for figure
zone_full_name.capitl = 'Capital';
zone_full_name.centrl = 'Central';
zone_full_name.dunwod = 'Dunwoodie';
zone_full_name.genese = 'Genesee';
zone_full_name.hudvl = 'Hudson Valley';
zone_full_name.longil = 'Long Island';
zone_full_name.mhkvl = 'Mohawak Valley';
zone_full_name.millwd = 'Millwood';
zone_full_name.nyc = 'New York City';
zone_full_name.north = 'North';
zone_full_name.west = 'West';
zone_full_name.nyiso = 'NYISO';

% Train model (Cross Fitting)
Y_hat_CF = zeros(length(X_time), nCrossFit);
nnet = cell(length(ZONE_LIST),nCrossFit);

% Train ANN by zone, print results summary and plot error distribution
for zone = 1:length(ZONE_LIST)

    for k=1:nCrossFit

        % Set Neural Network
        nnet{zone,k} = feedforwardnet(nneurons);
        nnet{zone,k} = configure(nnet{zone,k}, X', Y_load(:,zone)');
        
        % Optimization options
        nnet{zone,k}.trainFcn = 'trainbr';
        nnet{zone,k}.trainParam.max_fail = 10;

        % Data division options
        nnet{zone,k}.divideFcn = 'divideind';
        nnet{zone,k}.divideParam.trainInd = trainInd{k};
        nnet{zone,k}.divideParam.valInd = valInd{k};
        nnet{zone,k}.divideParam.testInd = testInd;

        % Train Neural Network
        nnet{zone,k} = train(nnet{zone,k}, X', Y_load(:,zone)');

        % Predict load given time effect and weather conditions
        Y_hat_CF(:,k) = nnet{zone,k}(X')';

        % Control for Holiday effects (regression on time dummies)
        Y_hat_CF(:,k) = adjust_holiday_forecast(Y_hat_CF(:,k), Y_load(:,zone), ...
                day_index, holidays_index);

    end

    % Set prediction at median values
    Y_hat(:,zone) = median(Y_hat_CF,2);

    % Get NNet prediction and compute error
    error_NNet = (Y_load(:,zone) - Y_hat(:,zone))./ Y_load(:,zone);
    APE_NNet = abs(error_NNet);

    error_NYISO = (Y_load(:,zone) - Y_fload(:,zone)) ./ Y_load(:,zone);
    APE_NYISO = abs(error_NYISO);

    % Compute NNet prediction standard error for event study graph (by day)
    error_nnet = Y_load(testInd,zone) - Y_hat(testInd,zone);
    error_nnet = reshape(error_nnet,24,[])';
    sigma_hat = ones(1,24) * cov(error_nnet) * ones(24,1);
    sigma_hat = sqrt(sigma_hat) / 24;

    % Compute load ratio
    index_3m = X_time >= datetime(2008,10,01) & X_time < datetime(2009,01,01);
    index_5m = X_time >= datetime(2008,10,01) & X_time < datetime(2009,03,01);
    ratio_3m = sum(Y_load(index_3m,zone)) / sum(Y_hat(index_3m,zone));
    ratio_5m = sum(Y_load(index_5m,zone)) / sum(Y_hat(index_5m,zone));
    
    % Log file: Print MAPE results and load ratio
    fprintf(fileID, fmt, upper(ZONE_LIST{zone}), ...
        mean(APE_NNet(testInd)), std(APE_NNet(testInd)), ...
        mean(APE_NYISO(testInd)), std(APE_NYISO(testInd)), ...
        sigma_hat, ratio_3m, ratio_5m);

    % Plot density of prediction error on Test set and train/val set
    [f_nnet_test, x_nnet_test] = ksdensity(error_NNet(testInd));
    [f_nalg_test, x_nalg_test] = ksdensity(error_NYISO(testInd));
    [f_nnet_train, x_nnet_train] = ksdensity(error_NNet(crossFitInd));
    [f_nalg_train, x_nalg_train] = ksdensity(error_NYISO(crossFitInd));
    figure(1); clf(1);
    set(gcf,'Color','White')
    set(gca, 'FontSize', 16)
    hold on
    plot(x_nnet_test,  f_nnet_test,  '-',  'color', color_matrix(1,:), 'LineWidth', 2.0);
    plot(x_nnet_train, f_nnet_train, '--', 'color', color_matrix(1,:), 'LineWidth', 2.0);
    plot(x_nalg_test,  f_nalg_test,  '-',  'color', color_matrix(2,:), 'LineWidth', 2.0);
    plot(x_nalg_train, f_nalg_train, '--', 'color', color_matrix(2,:), 'LineWidth', 2.0);
    hold off
    set(gca, 'xlim', [-0.25 0.25]);
    set(gca, 'ylim', [0 20]);
    legend('NNet - Test set', 'NNet - CFit set', 'NAlg - Test set', 'NAlg - CFit set');
    legend('box','off');
    legend('location','northeast');
    legend('FontSize',16);
    title(zone_full_name.(ZONE_LIST{zone}));

    figname = sprintf('%s/plot_error_%s.eps', dir_error, ZONE_LIST{zone});
    saveas(gcf, figname,'epsc');

end

% Close file with MAPE results and figures
fclose(fileID);
close all;

% Save neural network cellArray with index structure (zone x cross-fit sample)
nnet_index.trainInd = trainInd;
nnet_index.valInd = valInd;
nnet_index.testInd = testInd;
nnet_index.crossFitInd = crossFitInd;
nnet_index.predInd = predInd;
save(sprintf('nnet/neural_network_financial_%d_neurons.mat',nneurons), 'nnet', 'nnet_index');

% Save counterfactual NNet prediction results 
CLOAD = array2timetable(Y_hat, 'RowTimes', X_time);
CLOAD.Properties.VariableNames = ZONE_LIST;
writetimetable(CLOAD,sprintf('../results/load-counterfactual-financial-%d-neurons.csv',nneurons));
