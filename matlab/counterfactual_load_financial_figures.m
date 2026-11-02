project_root = setup_paths;
% Update path
addpath('fct/')

% Sample parameters
date_start = datetime(2005,02,01);
date_end = datetime(2009,03,01);
year_index_loss = 2007;

% Dropbox directory
dir_dropbox = project_root;
dir_result = fullfile(dir_dropbox, 'figures', 'results', 'financial');

% ----------------------------------------------------------------------------------------------- %
%%  Read LOAD, FLOAD and CLOAD data and read Log file                                             %
% ----------------------------------------------------------------------------------------------- %

% Read realized,forecasted and counterfactual load
TT.H.LOAD = readtimetable('../data/load-realized.csv');
TT.H.FLOAD = readtimetable('../data/load-forecasted.csv');
TT.H.CLOAD = readtimetable('../results/load-counterfactual-financial-10-neurons.csv');

% Select observations between date_start and date_end
TT.H.LOAD = TT.H.LOAD(TT.H.LOAD.Time > date_start & TT.H.LOAD.Time < date_end,:);
TT.H.FLOAD = TT.H.FLOAD(TT.H.FLOAD.Time > date_start & TT.H.FLOAD.Time < date_end,:);

% Adjust NYISO forecast to include losses (using Hourly data)
index = year(TT.H.LOAD.Time) <= year_index_loss;
ZONE_LIST = TT.H.LOAD.Properties.VariableNames;
for zone = 1:length(ZONE_LIST)
    % Compute loss factor
    loss_factor = TT.H.FLOAD.(ZONE_LIST{zone})(index) - TT.H.LOAD.(ZONE_LIST{zone})(index);
    loss_factor = mean(loss_factor ./ TT.H.FLOAD.(ZONE_LIST{zone})(index));

    % Adjust forecast
    TT.H.FLOAD.(ZONE_LIST{zone}) = TT.H.FLOAD.(ZONE_LIST{zone}) * (1-loss_factor);
end

% Aggregate by Day and Week
TYPE_LIST = {'LOAD','FLOAD','CLOAD'};
for tload = 1:3
    TT.M.(TYPE_LIST{tload}) = fillmissing(retime(TT.H.(TYPE_LIST{tload}),'minutely'),'spline');
    TT.D.(TYPE_LIST{tload}) = retime(TT.H.(TYPE_LIST{tload}), 'daily', 'mean');
    TT.W.(TYPE_LIST{tload}) = retime(TT.H.(TYPE_LIST{tload}), 'weekly', 'mean');
end

% Read log file
T.LOG = readtable(fullfile(project_root,'log_forecast_financial_10_neurons'));
T.LOG.Var9 = [];
T.LOG.Properties.VariableNames = {'Zone','NN_mean','NN_Std','NA_mean','N_std','DStd','R3m','R5m'};


% Compute Absolute prediction error and store result in timetable
ape_matrix = zeros(height(TT.H.LOAD),length(ZONE_LIST),2);
for zone = 1:length(ZONE_LIST)
    Y_load = TT.H.LOAD.(ZONE_LIST{zone});
    Y_fload = TT.H.FLOAD.(ZONE_LIST{zone});
    Y_hat = TT.H.CLOAD.(ZONE_LIST{zone});
    ape_matrix(:,zone,1) = abs((Y_load - Y_hat)./ Y_load);
    ape_matrix(:,zone,2) = abs((Y_load - Y_fload)./ Y_load);
end

% Create Hourly/Daily/Weekly timetable
Time = TT.H.LOAD.Time;
TT.H.APE.NNET = array2timetable(ape_matrix(:,:,1), 'VariableNames', ZONE_LIST, 'RowTime', Time);
TT.D.APE.NNET = retime(TT.H.APE.NNET, 'daily', 'mean');
TT.W.APE.NNET = retime(TT.H.APE.NNET, 'weekly', 'mean');
TT.H.APE.NALG = array2timetable(ape_matrix(:,:,2), 'VariableNames', ZONE_LIST, 'RowTime', Time);
TT.D.APE.NALG = retime(TT.H.APE.NALG, 'daily', 'mean');
TT.W.APE.NALG = retime(TT.H.APE.NALG, 'weekly', 'mean');
 
% ----------------------------------------------------------------------------------------------- %
%%  Zone name format for tables and figures                                                       %
% ----------------------------------------------------------------------------------------------- %

% Initialize color matrix
color_matrix = linspecer(6);

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


% Get zone full name for figure
zone_table_name.capitl = 'Capital';
zone_table_name.centrl = 'Central';
zone_table_name.dunwod = 'Dunwood.';
zone_table_name.genese = 'Genesee';
zone_table_name.hudvl = 'Hudson V.';
zone_table_name.longil = 'Long Isl.';
zone_table_name.mhkvl = 'Mohawk V.';
zone_table_name.millwd = 'Millwood';
zone_table_name.nyc = 'NYC';
zone_table_name.north = 'North';
zone_table_name.west = 'West';
zone_table_name.nyiso = 'NYISO';

% ----------------------------------------------------------------------------------------------- %
%%  Counterfactual prediction and event study graph                                               %
% ----------------------------------------------------------------------------------------------- %

for zone = 1:length(ZONE_LIST)

    % Unpack load variables
    Y_load = TT.D.LOAD.(ZONE_LIST{zone});
    Y_fload = TT.D.FLOAD.(ZONE_LIST{zone});
    Y_cload = TT.D.CLOAD.(ZONE_LIST{zone});

    % Actual and Counterfactual load (March 1st, 2020 to March 1st, 2021)
    index = TT.D.LOAD.Time >= datetime(2008,09,01) & TT.D.LOAD.Time < datetime(2009,03,01);
    Time = TT.D.LOAD.Time(index);
    Y_load_smooth = movavg(Y_load,'simple',14);
    Y_cload_smooth = movavg(Y_cload,'simple',14);
    figure(1); clf(1);
    set(gcf, 'Color', 'White')
    hold on
    plot(Time, Y_load_smooth(index) ./1000,  '-', 'color', color_matrix(2,:), 'LineWidth', 3.0);
    plot(Time, Y_cload_smooth(index) ./1000, '-', 'color', color_matrix(1,:), 'LineWidth', 3.0);
    plot(Time, Y_load(index) ./1000, '--', 'color', [color_matrix(2,:) 0.5], 'LineWidth', 1.0);
    plot(Time, Y_cload(index) ./1000,'--', 'color', [color_matrix(1,:) 0.5], 'LineWidth', 1.0);
    hold off
    set(gca,'xlim',[datetime(2008,09,01) datetime(2009,03,01)]);
    set(gca,'xtickLabelRotation',0);
    set(gca,'FontSize', 18);
    set(gca,'box', 'on');
    ylabel('Load (GW)');
    legend('Observed load', 'Counterfactual load');
    legend('box','on');
    legend('location','northwest');
    title(zone_full_name.(ZONE_LIST{zone}),'fontweight','normal');
    saveas(gcf, sprintf('%s/plot_counterfactual_%s.eps', dir_result, ZONE_LIST{zone}), 'epsc');


    % Even study graph - Difference Actual/Counterfactual load
    index = TT.D.LOAD.Time >= datetime(2008,09,01) & TT.D.LOAD.Time < datetime(2009,03,01);
    Time = TT.D.LOAD.Time(index);
    Y_diff_smooth = movavg(Y_load - Y_cload, 'simple', 14);
    sigma_hat = std(Y_diff_smooth(~index));
    lambda = fzero(@(lambda) mean(abs(Y_diff_smooth(~index)) < lambda*sigma_hat)-0.95, 1.0);
    Y_diff_ub = (Y_diff_smooth(index) + lambda*sigma_hat) ./ 1000;
    Y_diff_lb = (Y_diff_smooth(index) - lambda*sigma_hat) ./ 1000;
    X_fill = [Time', fliplr(Time')];
    Y_fill = [Y_diff_lb', fliplr(Y_diff_ub')];
    figure(2); clf(2);
    set(gcf,'Color','White')
    hold on
    xline(datetime(2008,09,15), ':', 'color', color_matrix(4,:), 'LineWidth', 3.0);
    plot(Time, Y_diff_smooth(index)./1000 ,'-' , 'color', color_matrix(2,:), 'LineWidth', 2.0);
    fill(X_fill, Y_fill, color_matrix(2,:), 'FaceAlpha',0.2, 'EdgeAlpha', 0.0);
    yline(0, ':', 'color', [0.0;0.0;0.0;0.5], 'LineWidth', 1.0);
    hold off
    set(gca,'xlim',[datetime(2008,09,01) datetime(2009,03,01)]);
    set(gca,'FontSize', 18);
    set(gca,'box', 'on');
    ylabel('Load difference (GW)');
    legend('Lehman Brothers Bankruptcy');
    legend('location','southeast');
    title(zone_full_name.(ZONE_LIST{zone}),'fontweight','normal');
    saveas(gcf, sprintf('%s/plot_event_%s.eps', dir_result, ZONE_LIST{zone}), 'epsc');

end
