project_root = setup_paths;
% 
% 
% 
% 

% Update path
addpath('fct/')

% Sample parameters
date_start = datetime(2015,01,01);
date_end = datetime(2021,03,01);
year_index_loss = 2019;

% Dropbox directory
dir_dropbox = project_root;
dir_result = fullfile(dir_dropbox, 'figures', 'results', 'covid');

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
%%  Read LOAD, FLOAD and CLOAD data and read Log file                                             %
% ----------------------------------------------------------------------------------------------- %

% Read realized,forecasted and counterfactual load
TT.H.LOAD = readtimetable('../data/load-realized.csv');
TT.H.FLOAD = readtimetable('../data/load-forecasted.csv');
TT.H.CLOAD = readtimetable('../results/load-counterfactual-covid-10-neurons.csv');

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
T.LOG = readtable(fullfile(project_root,'log_forecast_covid_10_neurons'));
T.LOG.Var9 = [];
T.LOG.Properties.VariableNames = {'Zone','NN_mean','NN_Std','NA_mean','N_std','DStd','R3m','R12m'};


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
%%  Figure: MAPE bar graph (testing set)                                                          %
% ----------------------------------------------------------------------------------------------- %

X_bar_name = cellfun(@(z) zone_table_name.(lower(z)), T.LOG.Zone, 'UniformOutput', false);
X_bar_plot = reordercats(categorical(X_bar_name), X_bar_name);

figure(1); clf(1);
set(gcf,'color','white');
set(gcf,'units','inch','position',[0 0 9.0 4.5]);
bar_plot = bar(X_bar_plot, 100*[T.LOG.NN_mean T.LOG.NA_mean]);
bar_plot(1).FaceColor = color_matrix(1,:);
bar_plot(1).FaceAlpha = 0.5;
bar_plot(1).EdgeAlpha = 0.5;
bar_plot(1).EdgeColor = color_matrix(1,:);
bar_plot(2).FaceColor = color_matrix(2,:);
bar_plot(2).EdgeColor = color_matrix(2,:);
grid('on')
set(gca,'fontSize',12);
set(gca,'xtickLabelRotation',45);
legend('Feed-forward network predictions','NYISO day-ahead forecasts');
legend('box','on');
legend('location','northwest');
ylabel('Mean absolute prediction error (%)');
saveas(gcf, sprintf('%s/plot_mape_testset.eps', dir_result), 'epsc');
close(gcf)


% --------------------  --------------------------------------------------------------------------- %
%%  Figure: Counterfactual prediction and event study graph                                       %
% ----------------------------------------------------------------------------------------------- %

% tableID = fopen(fullfile(dir_dropbox,'log_avg_daily_prediction_std_covid_10_neurons'),'w');
% fmt = '%10s \t\t %7.2f \t %7.2f \t %7.2f \n';
% shat = zeros(length(ZONE_LIST);

for zone = 1:length(ZONE_LIST)

    % Unpack load variables
    Y_load = TT.D.LOAD.(ZONE_LIST{zone});
    Y_fload = TT.D.FLOAD.(ZONE_LIST{zone});
    Y_cload = TT.D.CLOAD.(ZONE_LIST{zone});

    % Set smoothing window    
    smoothing_window = 14;
    
    % Actual and Counterfactual load (March 1st, 2020 to March 1st, 2021)
    index = TT.D.LOAD.Time >= datetime(2020,01,01);
    Time = TT.D.LOAD.Time(index);
    Y_load_smooth = movavg(Y_load, 'simple', smoothing_window);
    Y_cload_smooth = movavg(Y_cload, 'simple', smoothing_window);
    figure(1); clf(1);
    set(gcf, 'Color', 'White')
    hold on
    plot(Time, Y_load_smooth(index) ./1000,  '-', 'color', color_matrix(2,:), 'LineWidth', 3.0);
    plot(Time, Y_cload_smooth(index) ./1000, '-', 'color', color_matrix(1,:), 'LineWidth', 3.0);
    plot(Time, Y_load(index) ./1000, '--', 'color', [color_matrix(2,:) 0.5], 'LineWidth', 1.0);
    plot(Time, Y_cload(index) ./1000,'--', 'color', [color_matrix(1,:) 0.5], 'LineWidth', 1.0);
    hold off
    set(gca, 'xlim', [datetime(2020,01,01) datetime(2021,03,01)]);
    set(gca, 'xtickLabelRotation', 0)
    set(gca, 'FontSize', 18);
    set(gca, 'box', 'on');
    ylabel('Load (GW)');
    legend('Observed load', 'Counterfactual load');
    legend('box','on');
    legend('location','northwest');
    title(zone_full_name.(ZONE_LIST{zone}),'fontweight','normal');
    saveas(gcf, sprintf('%s/plot_counterfactual_%s.eps', dir_result, ZONE_LIST{zone}), 'epsc');


    % Even study graph - Difference Actual/Counterfactual load
    index = TT.D.LOAD.Time >= datetime(2020,01,01);
    Time = TT.D.LOAD.Time(index);
    Y_diff_smooth = movavg(Y_load - Y_cload, 'simple', smoothing_window);
    lambda_sym = fzero(@(lambda) mean(abs(Y_diff_smooth(~index)) < lambda)-0.95, 1.0);
    lambda_ub = fzero(@(lambda) mean(abs(max(Y_diff_smooth(~index),0)) < lambda)-0.975, 1.0);
    lambda_lb = fzero(@(lambda) mean(abs(min(Y_diff_smooth(~index),0)) < lambda)-0.975, 1.0);
    % shat(zone) = lambda*sigma_hat/1.96;
    % Y_diff_ub = (Y_diff_smooth(index) + lambda_sym) ./ 1000;
    % Y_diff_lb = (Y_diff_smooth(index) - lambda_sym) ./ 1000;
    Y_diff_ub = (Y_diff_smooth(index) + lambda_ub) ./ 1000;
    Y_diff_lb = (Y_diff_smooth(index) - lambda_lb) ./ 1000;
    X_fill = [Time', fliplr(Time')];
    Y_fill = [Y_diff_lb', fliplr(Y_diff_ub')];
    figure(2); clf(2);
    set(gcf,'Color','White')
    hold on
    xline(datetime(2020,03,01), ':', 'color', color_matrix(4,:), 'LineWidth', 3.0);
    xline(datetime(2020,03,23), ':', 'color', color_matrix(5,:), 'LineWidth', 3.0);
    plot(Time, Y_diff_smooth(index)./1000 , '-' , 'color', color_matrix(2,:), 'LineWidth', 2.0);
    fill(X_fill, Y_fill, color_matrix(2,:), 'FaceAlpha', 0.2, 'EdgeAlpha', 0.0);
    yline(0, ':', 'color', [0.0;0.0;0.0;0.5], 'LineWidth', 1.0);
    hold off
    set(gca, 'xlim', [datetime(2020,01,01) datetime(2021,03,01)]);
    set(gca, 'FontSize', 18);
    set(gca, 'box', 'on');
    ylabel('Load difference (GW)');
    legend('box','on');
    legend('location','southeast');
    legend('1st reported COVID-19 case in NY', ...
           'Lockdown');
    title(zone_full_name.(ZONE_LIST{zone}),'fontweight','normal');
    saveas(gcf, sprintf('%s/plot_event_%s.eps', dir_result, ZONE_LIST{zone}), 'epsc');


    % Print smoothed daily prediction std
    % fprintf(tableID, fmt, ZONE_LIST{zone}, sigma_hat, lambda, lambda*sigma_hat/1.96);

end
% fclose(tableID);
close all

% ----------------------------------------------------------------------------------------------- %
%%  Figure: Demand reduction around lockdown                                                      %
% ----------------------------------------------------------------------------------------------- %

% Demand reduction around lockdown (4 months)
index = TT.M.LOAD.Time >= datetime(2020,02,01) & TT.M.LOAD.Time < datetime(2020,06,01);
Time = TT.M.LOAD.Time(index);
Y_load_smooth = movavg(TT.M.LOAD.nyiso, 'simple', 60*48) ./ 1000;
Y_fload_smooth = movavg(TT.M.FLOAD.nyiso, 'simple', 60*48) ./ 1000;
Y_cload_smooth = movavg(TT.M.CLOAD.nyiso, 'simple', 60*48) ./ 1000;
figure(3); clf(3);
set(gcf, 'Color', 'White')
hold on
plot(Time, Y_load_smooth(index),  '-' , 'color', color_matrix(2,:), 'LineWidth', 2.0);
plot(Time, Y_fload_smooth(index), '--', 'color', color_matrix(2,:), 'LineWidth', 2.0);
plot(Time, Y_cload_smooth(index), '-.', 'color', color_matrix(1,:), 'LineWidth', 2.0);
xline(datetime(2020,03,01), ':', 'color', color_matrix(4,:), 'LineWidth', 3.0);
xline(datetime(2020,03,15), ':', 'color', color_matrix(3,:), 'LineWidth', 3.0);
xline(datetime(2020,03,23), ':', 'color', color_matrix(5,:), 'LineWidth', 3.0);
hold off
set(gca, 'xlim', [datetime(2020,02,01) datetime(2020,06,01)]);
set(gca, 'xtickLabel', {'Feb','Mar','Apr','May','Jun'});
set(gca, 'ylim', [10.80 20.20])
set(gca, 'FontSize', 14);
set(gca, 'box', 'on');
ylabel('Load (GW)');
legend('Observed load', ...
       'NYSIO day-head forecast', ...
       'Counterfactual load', ...
       '1st reported COVID-19 case in NY', ...
       'Schools closure', ...
       'Lockdown');
legend('numcolumns',2);
legend('location','southwest');
saveas(gcf, sprintf('%s/plot_reduction_4months_nyiso.eps', dir_result), 'epsc');


% Demand reduction after lockdown (1 week)
index = TT.M.LOAD.Time >= datetime(2020,03,23) & TT.M.LOAD.Time <= datetime(2020,03,30);
Time = TT.M.LOAD.Time(index);
Y_load_smooth = movavg(TT.M.LOAD.nyiso, 'simple', 60*2) ./ 1000;
Y_fload_smooth = movavg(TT.M.FLOAD.nyiso, 'simple', 60*2) ./ 1000;
Y_cload_smooth = movavg(TT.M.CLOAD.nyiso, 'simple', 60*2) ./ 1000;
figure(4); clf(4);
set(gcf, 'Color', 'White')
hold on
plot(Time, Y_load_smooth(index),  '-' , 'color', color_matrix(2,:), 'LineWidth', 2.0);
plot(Time, Y_fload_smooth(index), '--', 'color', color_matrix(2,:), 'LineWidth', 2.0);
plot(Time, Y_cload_smooth(index), '-.', 'color', color_matrix(1,:), 'LineWidth', 2.0);
hold off
set(gca, 'xlim', [datetime(2020,03,23) datetime(2020,03,30)]);
set(gca, 'xtickLabel',{'Mar 23','Mar 24','Mar 25','Mar 26','Mar 27','Mar 28','Mar 29','Mar 30',});
set(gca, 'ylim', [10.80 20.20])
set(gca, 'FontSize', 14);
set(gca, 'box', 'on');
ylabel('Load (GW)');
legend('Observed load', ...
       'NYSIO day-head forecast', ...
       'Counterfactual load');
legend('location','southwest');
saveas(gcf, sprintf('%s/plot_reduction_1week_nyiso.eps', dir_result), 'epsc');

% ----------------------------------------------------------------------------------------------- %
%%  Figure: Load pattern (Weekends / Weekdays)                                                    %
% ----------------------------------------------------------------------------------------------- %

% March 23 to May 3, 2020 (6 weeks)
period(:,1) = TT.M.LOAD.Time >= datetime(2020,03,23) & TT.M.LOAD.Time <= datetime(2020,04,14);
period(:,2) = TT.M.LOAD.Time >= datetime(2020,04,15) & TT.M.LOAD.Time <= datetime(2020,05,03);
weekday_index = any(weekday(TT.M.LOAD.Time) == [2 3 4 5 6], 2);
weekend_index = any(weekday(TT.M.LOAD.Time) == [1 7], 2);

% Get time of day
tod = timeofday(TT.M.LOAD.Time);
tod_unique = unique(tod);
tod_unique.Format = 'hh:mm';

% Compute average load pattern (in GwH)
load_pattern_weekend = zeros(length(tod_unique),2,size(period,2));
load_pattern_weekday = zeros(length(tod_unique),2,size(period,2));
for i=1:length(tod_unique)
    for p=1:size(period,2)
        % Weekend
        index = period(:,p) & weekend_index;
        load_pattern_weekend(i,1,p) = mean(TT.M.LOAD.nyiso(index & tod == tod_unique(i))) / 1000;
        load_pattern_weekend(i,2,p) = mean(TT.M.CLOAD.nyiso(index & tod == tod_unique(i))) / 1000;

        % Weekday
        index = period(:,p) & weekday_index;
        load_pattern_weekday(i,1,p) = mean(TT.M.LOAD.nyiso(index & tod == tod_unique(i))) / 1000;
        load_pattern_weekday(i,2,p) = mean(TT.M.CLOAD.nyiso(index & tod == tod_unique(i))) / 1000;
    end
end


% Peak for realized load (weekend)
peak_load(1,1) = max(load_pattern_weekend(tod_unique < '15:00',1,1));
peak_load(1,2) = max(load_pattern_weekend(tod_unique < '15:00',1,2));
peak_load(2,1) = max(load_pattern_weekend(tod_unique > '15:00',1,1));
peak_load(2,2) = max(load_pattern_weekend(tod_unique > '15:00',1,2));

peak_index_load(1,1) = find(load_pattern_weekend(:,1,1) == peak_load(1,1),1);
peak_index_load(1,2) = find(load_pattern_weekend(:,1,2) == peak_load(1,2),1);
peak_index_load(2,1) = find(load_pattern_weekend(:,1,1) == peak_load(2,1),1);
peak_index_load(2,2) = find(load_pattern_weekend(:,1,2) == peak_load(2,2),1);

% Peak for counterfactual load (weekend)
peak_cload(1,1) = max(load_pattern_weekend(tod_unique < '15:00',2,1));
peak_cload(1,2) = max(load_pattern_weekend(tod_unique < '15:00',2,2));
peak_cload(2,1) = max(load_pattern_weekend(tod_unique > '15:00',2,1));
peak_cload(2,2) = max(load_pattern_weekend(tod_unique > '15:00',2,2));

peak_index_cload(1,1) = find(load_pattern_weekend(:,2,1) == peak_cload(1,1),1);
peak_index_cload(1,2) = find(load_pattern_weekend(:,2,2) == peak_cload(1,2),1);
peak_index_cload(2,1) = find(load_pattern_weekend(:,2,1) == peak_cload(2,1),1);
peak_index_cload(2,2) = find(load_pattern_weekend(:,2,2) == peak_cload(2,2),1);

% Get peak time of day 'hh:mm'
peak_time_load = tod_unique(peak_index_load);
peak_time_cload = tod_unique(peak_index_cload);

close(1); figure(1); clf(1);
set(gcf, 'color','white');
hold on
plot(tod_unique, load_pattern_weekend(:,1,1), '-', 'color', color_matrix(2,:), 'LineWidth', 2.0);
plot(tod_unique, load_pattern_weekend(:,2,1), '-', 'color', color_matrix(1,:), 'LineWidth', 2.0);
plot(tod_unique, load_pattern_weekend(:,1,2), '--', 'color', color_matrix(2,:), 'LineWidth', 2.0);
plot(tod_unique, load_pattern_weekend(:,2,2), '--', 'color', color_matrix(1,:), 'LineWidth', 2.0);
for j=1:4
    plot(peak_time_load(j), peak_load(j), 'o', 'color', color_matrix(2,:), 'LineWidth', 2.5);
    plot(peak_time_cload(j), peak_cload(j), 'o', 'color', color_matrix(1,:), 'LineWidth', 2.5);
    txt(j,1) = text(peak_time_load(j), peak_load(j), {datestr(peak_time_load(j),15)}, ...
        'color', color_matrix(2,:),'FontSize', 13);
    txt(j,2) = text(peak_time_cload(j), peak_cload(j), {datestr(peak_time_cload(j),15)}, ...
        'color', color_matrix(1,:), 'FontSize', 13);
end
hold off
txt(1,1).Position = txt(1,1).Position + [-0.085 0.105 0];
txt(2,1).Position = txt(2,1).Position + [-0.085 0.105 0];
txt(1,2).Position = txt(1,2).Position + [-0.085 0.105 0];
txt(2,2).Position = txt(2,2).Position + [-0.085 0.105 0];
txt(3,1).Position = txt(3,1).Position + [ 0.015 0.105 0];
txt(3,2).Position = txt(3,2).Position + [ 0.015 0.105 0];
txt(4,1).Position = txt(4,1).Position + [ 0.015 0.105 0];
txt(4,2).Position = txt(4,2).Position + [ 0.015 0.105 0];
set(gca,'xlim',[tod_unique(1) tod_unique(end)]);
set(gca,'xtick',tod_unique([5 10 15 20].*60+1));
set(gca,'ylim',[11.80 18.20])
set(gca,'FontSize',14);
set(gca,'box','on');
ylabel('Load (GW)')
legend('Avg. daily load (Mar. 23 to Apr. 14)', ...
       'Counterfactual avg. daily load (Mar. 23 to Apr. 14)', ...
       'Avg. daily load (Apr. 15  to May 3)', ...
       'Counterfactual avg. daily load (Apr. 15 to May 3)');
legend('location','northwest');
legend('box','on');
saveas(gcf, sprintf('%s/plot_load_pattern_weekend.eps', dir_result), 'epsc');


% Peak for realized load (weekday)
peak_load(1,1) = max(load_pattern_weekday(tod_unique < '15:00',1,1));
peak_load(1,2) = max(load_pattern_weekday(tod_unique < '15:00',1,2));
peak_load(2,1) = max(load_pattern_weekday(tod_unique > '15:00',1,1));
peak_load(2,2) = max(load_pattern_weekday(tod_unique > '15:00',1,2));

peak_index_load(1,1) = find(load_pattern_weekday(:,1,1) == peak_load(1,1),1);
peak_index_load(1,2) = find(load_pattern_weekday(:,1,2) == peak_load(1,2),1);
peak_index_load(2,1) = find(load_pattern_weekday(:,1,1) == peak_load(2,1),1);
peak_index_load(2,2) = find(load_pattern_weekday(:,1,2) == peak_load(2,2),1);

% Peak for counterfactual load (weekday)
peak_cload(1,1) = max(load_pattern_weekday(tod_unique < '15:00',2,1));
peak_cload(1,2) = max(load_pattern_weekday(tod_unique < '15:00',2,2));
peak_cload(2,1) = max(load_pattern_weekday(tod_unique > '15:00',2,1));
peak_cload(2,2) = max(load_pattern_weekday(tod_unique > '15:00',2,2));

peak_index_cload(1,1) = find(load_pattern_weekday(:,2,1) == peak_cload(1,1),1);
peak_index_cload(1,2) = find(load_pattern_weekday(:,2,2) == peak_cload(1,2),1);
peak_index_cload(2,1) = find(load_pattern_weekday(:,2,1) == peak_cload(2,1),1);
peak_index_cload(2,2) = find(load_pattern_weekday(:,2,2) == peak_cload(2,2),1);

% Get peak time of day 'hh:mm'
peak_time_load = tod_unique(peak_index_load);
peak_time_cload = tod_unique(peak_index_cload);


close(1); figure(1); clf(1);
set(gcf, 'color','white');
hold on
plot(tod_unique, load_pattern_weekday(:,1,1), '-', 'color', color_matrix(2,:), 'LineWidth', 2.0);
plot(tod_unique, load_pattern_weekday(:,2,1), '-', 'color', color_matrix(1,:), 'LineWidth', 2.0);
plot(tod_unique, load_pattern_weekday(:,1,2), '--', 'color', color_matrix(2,:), 'LineWidth', 2.0);
plot(tod_unique, load_pattern_weekday(:,2,2), '--', 'color', color_matrix(1,:), 'LineWidth', 2.0);
for j=1:4
    plot(peak_time_load(j), peak_load(j), 'o', 'color', color_matrix(2,:), 'LineWidth', 2.5);
    plot(peak_time_cload(j), peak_cload(j), 'o', 'color', color_matrix(1,:), 'LineWidth', 2.5);
    txt(j,1) = text(peak_time_load(j), peak_load(j), {datestr(peak_time_load(j),15)}, ...
        'color', color_matrix(2,:),'FontSize', 13);
    txt(j,2) = text(peak_time_cload(j), peak_cload(j), {datestr(peak_time_cload(j),15)}, ...
        'color', color_matrix(1,:), 'FontSize', 13);
end
hold off
txt(1,1).Position = txt(1,1).Position + [-0.085 0.105 0];
txt(2,1).Position = txt(2,1).Position + [-0.085 0.105 0];
txt(1,2).Position = txt(1,2).Position + [-0.085 0.105 0];
txt(2,2).Position = txt(2,2).Position + [-0.085 0.105 0];
txt(3,1).Position = txt(3,1).Position + [ 0.015 0.105 0];
txt(3,2).Position = txt(3,2).Position + [ 0.015 0.105 0];
txt(4,1).Position = txt(4,1).Position + [ 0.015 0.105 0];
txt(4,2).Position = txt(4,2).Position + [ 0.015 0.105 0];
set(gca, 'xlim', [tod_unique(1) tod_unique(end)]);
set(gca, 'xtick', tod_unique([5 10 15 20].*60+1));
set(gca, 'ylim', [11.80 18.20])
set(gca, 'FontSize', 14);
set(gca, 'box', 'on');
ylabel('Load (GW)')
legend('Avg. daily load (Mar. 23 to Apr. 14)', ...
       'Counterfactual avg. daily load (Mar. 23 to Apr. 14)', ...
       'Avg. daily load (Apr. 15  to May 3)', ...
       'Counterfactual avg. daily load (Apr. 15 to May 3)');
legend('location','southeast');
legend('box','on');
saveas(gcf, sprintf('%s/plot_load_pattern_weekday.eps', dir_result), 'epsc');

% ----------------------------------------------------------------------------------------------- %
%%  Table: Descriptive statistics (Load)                                                          %
% ----------------------------------------------------------------------------------------------- %

index_pre_covid = year(TT.H.LOAD.Time)<= 2019;
index_covid = year(TT.H.LOAD.Time) >= 2020;
descriptive_stats = zeros(length(ZONE_LIST),4,2);
for zone =1:length(ZONE_LIST)
    % Descriptive statistics before COVID
    Y_load = TT.H.LOAD.(ZONE_LIST{zone})(index_pre_covid)/1000;
    descriptive_stats(zone,1,1) = mean(Y_load);
    descriptive_stats(zone,2,1) = std(Y_load);
    descriptive_stats(zone,3,1) = quantile(Y_load,0.05);
    descriptive_stats(zone,4,1) = quantile(Y_load,0.95);
    % Descriptive statistics during COVID
    Y_load = TT.H.LOAD.(ZONE_LIST{zone})(index_covid)/1000;
    descriptive_stats(zone,1,2) = mean(Y_load);
    descriptive_stats(zone,2,2) = std(Y_load);
    descriptive_stats(zone,3,2) = quantile(Y_load,0.05);
    descriptive_stats(zone,4,2) = quantile(Y_load,0.95);
end

% Print table
tableID = fopen(fullfile(dir_dropbox,'tables','table_descriptive_stats_load.tex'), 'w');
fmt = '%10s & %5.2f & %5.2f & %5.2f & %5.2f & %5.2f & %5.2f & %5.2f & %5.2f \\\\\n';
for zone=1:length(ZONE_LIST)
    fprintf(tableID, fmt, zone_table_name.(ZONE_LIST{zone}), descriptive_stats(zone,:,:));
end
fclose(tableID);

% ----------------------------------------------------------------------------------------------- %
%%  Table: Demand reduction weekend/weekdays                                                      %
% ----------------------------------------------------------------------------------------------- %

% Prepare timetable in minutes
load_reduction = zeros(height(TT.M.LOAD), length(ZONE_LIST));
for zone = 1:length(ZONE_LIST)
    Y_load = TT.M.LOAD.(ZONE_LIST{zone});
    Y_hat = TT.M.CLOAD.(ZONE_LIST{zone});
    load_reduction(:,zone) = (Y_load - Y_hat) ./ Y_hat;
end
Time = TT.M.LOAD.Time;
TT.M.RLOAD = array2timetable(load_reduction, 'VariableNames', ZONE_LIST, 'RowTime', Time);

% March 23 to May 3, 2020 (6 weeks)
period_index = TT.M.RLOAD.Time >= datetime(2020,03,23) & TT.M.RLOAD.Time <= datetime(2020,05,03);

% Day of week index
weekday_index = any(weekday(TT.M.RLOAD.Time) == [2 3 4 5 6], 2);
weekend_index = ~weekday_index;

% Daily period index
time_of_day = timeofday(TT.M.RLOAD.Time);
night_index = time_of_day > '22:00:00' | time_of_day <= '06:00:00';
morning_index = time_of_day > '06:00:00' & time_of_day <= '12:00:00';
afternoon_index = time_of_day > '12:00:00' & time_of_day <= '18:00:00';
evening_index = time_of_day > '18:00:00' & time_of_day <= '22:00:00';

% Compute average reductions 
avg_reduction = zeros(length(ZONE_LIST),4,2);
for zone = 1:length(ZONE_LIST)
    index = period_index & weekday_index;
    avg_reduction(zone,1,2) = mean(TT.M.RLOAD.(ZONE_LIST{zone})(index & night_index));
    avg_reduction(zone,2,2) = mean(TT.M.RLOAD.(ZONE_LIST{zone})(index & morning_index));
    avg_reduction(zone,3,2) = mean(TT.M.RLOAD.(ZONE_LIST{zone})(index & afternoon_index));
    avg_reduction(zone,4,2) = mean(TT.M.RLOAD.(ZONE_LIST{zone})(index & evening_index));

    index = period_index & weekend_index;
    avg_reduction(zone,1,1) = mean(TT.M.RLOAD.(ZONE_LIST{zone})(index & night_index));
    avg_reduction(zone,2,1) = mean(TT.M.RLOAD.(ZONE_LIST{zone})(index & morning_index));
    avg_reduction(zone,3,1) = mean(TT.M.RLOAD.(ZONE_LIST{zone})(index & afternoon_index));
    avg_reduction(zone,4,1) = mean(TT.M.RLOAD.(ZONE_LIST{zone})(index & evening_index));
end


tableID = fopen(fullfile(dir_dropbox,'tables','table_load_reduction.tex'), 'w');
fmt = '%6.1f & %6.1f & %6.1f & %6.1f ';
fmt = sprintf('%s & %s & %s \\\\\\\\\n', '%10s', fmt, fmt);
for zone=1:length(ZONE_LIST)
    fprintf(tableID, fmt, zone_table_name.(ZONE_LIST{zone}), 100*avg_reduction(zone,:,:));
end
fclose(tableID);

% ----------------------------------------------------------------------------------------------- %
%%  Table: Descriptive statistics (Weather variables)                                             %
% ----------------------------------------------------------------------------------------------- %

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
fmtCell{1} = ' %6.1f & (%6.1f) & %6.1f & (%6.1f) & %6.1f & (%6.1f) &';
fmtCell{2} = ' %6.1f & (%6.1f) & %6.1f & (%6.1f) & %6.1f & (%6.1f) &';
fmtCell{3} = ' %6.0f & (%6.0f) ';
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


% ----------------------------------------------------------------------------------------------- %
%%  Figure: Cross-Fitting results (NYSIO)                                                         %
% ----------------------------------------------------------------------------------------------- %

% % TO MOVE TO COUNTERFACTUAL_LOAD_COVID_NNET.M file

% % Read holidays list
% HOLIDAYS = readtable('../data/holidays.csv');

% % Set day index/prepare holidays index
% day_index = unique(X_time - timeofday(X_time));
% holidays_index = zeros(length(day_index),1);
% for i=1:height(HOLIDAYS)
%     holidays_index(day_index == HOLIDAYS.date(i)) = HOLIDAYS.index(i);
% end

% addpath('fct');

% index = TT.H.LOAD.Time > datetime(2015,01,01) & TT.H.LOAD.Time < datetime(2021,03,01);
% X_time = TT.H.LOAD.Time(index); 
% X_datetime = prepare_datetime_variables(X_time);
% X_weather = prepare_weather_variables(X_time);
% X = [X_datetime X_weather];
% Y = TT.H.LOAD.nyiso(index);

% Y_hat = zeros(length(X_time),5);
% for k=1:5
%     Y_hat(:,k) = nnet{12,k}(X')';
%     Y_had(:,k) = adjust_holiday_forecast(Y_hat(:,k), Y, day_index, holidays_index);
% end


% TT.H.Yhat = array2timetable(Y_hat, 'RowTime', X_time);
% TT.D.Yhat = retime(TT.H.Yhat, 'daily', 'mean');

% index = TT.D.Yhat.Time >= datetime(2020,01,01) & TT.D.Yhat.Time < datetime(2021,03,01);
% Y_hat_daily = movavg(TT.D.Yhat.Variables, 'simple', 7);
% Y_hat_daily = Y_hat_daily(index,:) ./ 1000;
% Y_daily = movavg(TT.D.LOAD.nyiso, 'simple', 7) ;
% Y_daily = Y_daily(index,:) ./ 1000;
% X_time_daily = TT.D.Yhat.Time(index);

% figure(1); clf(1);
% set(gcf, 'color','white');
% set(gcf, 'units', 'pixels', 'position', [1000 918 680 460], 'units', 'pixels');
% hold on
% f(1) = plot(X_time_daily, Y_daily, '-', 'color', color_matrix(1,:), 'LineWidth', 2.0);
% f(2) = plot(X_time_daily, median(Y_hat_daily,2),'-','color',color_matrix(2,:), 'LineWidth', 2.0);
% for k=1:5
%     f(2+k) = plot(X_time_daily, Y_hat_daily(:,k),'--','color',color_matrix(2,:), 'LineWidth', 1.5);
% end
% f(8) = xline(datetime(2020,03,01), ':', 'color', color_matrix(3,:), 'LineWidth', 2.0);
% f(9) = xline(datetime(2020,03,14), ':', 'color', color_matrix(4,:), 'LineWidth', 2.0);
% f(10) = xline(datetime(2020,03,22), ':', 'color', color_matrix(5,:), 'LineWidth', 2.0);
% hold off
% set(gca, 'xlim', [datetime(2020,01,01) datetime(2021,03,01)]);
% set(gca, 'ylim', [11.75 24.25]);
% set(gca, 'FontSize', 14);
% set(gca, 'box', 'on');
% ylabel('Load (GW)');
% legend(f([1 2 3 8 9 10]), ...
%        'Actual load', ...
%        'Cross-fitting predicted load', ...
%        'Sub-samples predicted load', ...
%        '1st reported case in NY', ...
%        'Schools closure', ...
%        'Lockdown');
% legend('box', 'on');
% legend('location', 'northeast');
% saveas(gcf, sprintf('%s/plot_crossfitting_prediction_nyiso.eps', dir_result), 'epsc');
