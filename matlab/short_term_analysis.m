project_root = setup_paths;
% File: short_term_analysis.m
% 

% ----------------------------------------------------------------------------------------------- %
%%   Read data                                                                                    %
% ----------------------------------------------------------------------------------------------- %
clear
project_root = setup_paths;
clc
close all
cd(fullfile(project_root,'matlab'))
addpath(fullfile(project_root,'data'));
addpath(fullfile(project_root,'results'));

% Read day ahead and real time market prices
TT.DAM = readtimetable('prices-electricity-day-ahead.csv');
TT.RTM = readtimetable('prices-electricity-real-time.csv');

% Read realized/forecasted/counterfactual load
TT.LOAD = readtimetable('load-realized.csv');
TT.FLOAD = readtimetable('load-forecasted.csv');
TT.CLOAD = readtimetable('load-counterfactual-covid-10-neurons.csv');

% Read Natural Gas prices and alternative energy sources
TT.GAS = readtimetable('prices-natural-gas.csv');
TT.ENERGY = readtimetable('alternative-energy-sources.csv');

% Read Holiday list
TT.HOLIDAYS = readtimetable('holidays.csv');

% ----------------------------------------------------------------------------------------------- %
%%   Prepare timetable for regression                                                             %
% ----------------------------------------------------------------------------------------------- %

% Specify a time range for balancing timetables
time_range = timerange("2016-01-01","2021-03-01");

% Create STRUCT with zone specific load timetable
ZONE_LIST = TT.LOAD.Properties.VariableNames;
for zone=1:length(ZONE_LIST)
    % Create zone specific timetable for LOAD variables 
    LOAD.(ZONE_LIST{zone}) = outerjoin(TT.LOAD(:,zone), TT.FLOAD(:,zone));
    LOAD.(ZONE_LIST{zone}) = outerjoin(LOAD.(ZONE_LIST{zone}), TT.CLOAD(:,zone));
    LOAD.(ZONE_LIST{zone}) = LOAD.(ZONE_LIST{zone})(time_range,:);
    LOAD.(ZONE_LIST{zone}).Properties.VariableNames = {'rlze', 'fcst', 'cfct'};

    % Adjust NYISO forecast for loss 
    index = year(LOAD.(ZONE_LIST{zone}).Time) < 2020;
    loss_factor = LOAD.(ZONE_LIST{zone}).fcst(index) - LOAD.(ZONE_LIST{zone}).rlze(index);
    loss_factor = mean(loss_factor ./ LOAD.(ZONE_LIST{zone}).fcst(index));
    LOAD.(ZONE_LIST{zone}).fcst = LOAD.(ZONE_LIST{zone}).fcst * (1-loss_factor);

    % Compute forecast and counterfactual error
    LOAD.(ZONE_LIST{zone}).ferr = LOAD.(ZONE_LIST{zone}).rlze - LOAD.(ZONE_LIST{zone}).fcst;
    LOAD.(ZONE_LIST{zone}).cerr = LOAD.(ZONE_LIST{zone}).rlze - LOAD.(ZONE_LIST{zone}).cfct;
end

% Create STRUCT with zone specific prices timetable
ZONE_LIST_PRICES = TT.DAM.Properties.VariableNames;
for zone=1:length(ZONE_LIST_PRICES)
    zone_name = ZONE_LIST_PRICES{zone};
    if( any(contains(ZONE_LIST, zone_name)) )
        PRICES.(zone_name) = outerjoin(TT.DAM(:,zone), TT.RTM(:,zone));
        PRICES.(zone_name) = PRICES.(zone_name)(time_range,:);
        PRICES.(zone_name).Properties.VariableNames = {'dam', 'rtm'};
        PRICES.(zone_name).spread = PRICES.(zone_name).dam - PRICES.(zone_name).rtm;
    end
end

% Add NYSIO prices timetable to PRICES
nyiso_dam = zeros(length(LOAD.nyiso.Time),1);
nyiso_rtm = zeros(length(LOAD.nyiso.Time),1);
for zone=1:length(ZONE_LIST)
    if( ~strcmp(ZONE_LIST{zone},'nyiso') )
        zone_dam = PRICES.(ZONE_LIST{zone}).dam;
        zone_rtm = PRICES.(ZONE_LIST{zone}).rtm;
        
        nyiso_dam = nyiso_dam + (zone_dam .* LOAD.(ZONE_LIST{zone}).rlze) ./ LOAD.nyiso.fcst;
        nyiso_rtm = nyiso_rtm + (zone_rtm .* LOAD.(ZONE_LIST{zone}).rlze) ./ LOAD.nyiso.fcst;
    end
end
PRICES.nyiso = array2timetable([nyiso_dam nyiso_rtm], 'RowTime', LOAD.nyiso.Time);
PRICES.nyiso.Properties.VariableNames = {'dam', 'rtm'};
PRICES.nyiso.spread = PRICES.nyiso.dam - PRICES.nyiso.rtm;
clear nyiso_dam nyiso_rtm zone_dam zone_rtm;

% Create STRUCT with weather observations (by station)
WEATHER_LIST = dir(fullfile(project_root,'data','weather-station-*')) %.csv');
for station=1:length(WEATHER_LIST)
    % Create station specific timetable for weather observations
    station_name = WEATHER_LIST(station).name(end-7:end-4);
    station_filename = fullfile(WEATHER_LIST(station).folder, WEATHER_LIST(station).name);
    WEATHER.(station_name) = readtimetable(station_filename);
    
    % Balance timetable
    WEATHER.(station_name) = WEATHER.(station_name)(time_range,:);
end

% Create NYISO timetable with aggregate load, gas price and alternative energy sources
newyork_index = find(contains(TT.GAS.Properties.VariableNames, 'newyork'));
henryhub_index = find(contains(TT.GAS.Properties.VariableNames, 'henryhub'));
NYISO = outerjoin(LOAD.nyiso, TT.GAS(:,newyork_index));
NYISO = outerjoin(NYISO, TT.GAS(:,henryhub_index));
NYISO = fillmissing(NYISO,'previous');
NYISO = NYISO(timeofday(NYISO.Time) ~= '0:00:00',:);
NYISO.Properties.VariableNames(end-1) = {'gasPrice'};
NYISO.Properties.VariableNames(end) = {'gasPrice_HH'};
NYISO = outerjoin(NYISO, TT.ENERGY);
NYISO = NYISO(time_range,:);

% Add holiday indexes to NYISO
for i=1:height(TT.HOLIDAYS)
    index = NYISO.Time-timeofday(NYISO.Time) == TT.HOLIDAYS.date(i);
    NYISO.holidays(index) = TT.HOLIDAYS.index(i);
end



% ----------------------------------------------------------------------------------------------- %
%% regressions                                                                                     %
% ----------------------------------------------------------------------------------------------- %

%% Natural gas
NYISO_d = retime(NYISO,'daily','mean');
NYISO_d_max = retime(NYISO,'daily','max');
NYISO_d_min = retime(NYISO,'daily','min');

WEATHER.kalb_d = retime(WEATHER.kalb,'daily','mean');
WEATHER.kalb_d_min = retime(WEATHER.kalb,'daily','min');
WEATHER.kalb_d_max = retime(WEATHER.kalb,'daily','max');

YEAR = [2019,2016];
for i = 1:2
    
    index1 = NYISO_d.Time >= datetime(YEAR(i),01,01) & NYISO_d.Time < datetime(2021,03,01); % estimation sample
    index2 = NYISO_d.Time >= datetime(2020,01,01) & NYISO_d.Time < datetime(2021,03,01); % 2020-2021
    
    X_treat = NYISO_d.Time>=datetime(2020,3,1);
    X_wday = dummyvar(weekday(NYISO_d.Time));  X_wday(:,1) = [];
    X_week = dummyvar(week(NYISO_d.Time));  X_week(:,1) = [];
    X_month = dummyvar(month(NYISO_d.Time));  X_month(:,1) = [];
    X_holidays = dummyvar(NYISO_d.holidays+1); X_holidays(:,1) = [];
    X = fourierbasis_time(NYISO_d.Time,11); %X_time vector of time var
    Y = NYISO_d.gasPrice(index1);

    X0 = [X_treat,WEATHER.kalb_d_min.temperature<=15,WEATHER.kalb_d.temperature,...
        ones(size(X,1),1),X_month,X_holidays,X_wday,... %,X_holidays
        ];
    
    X = X0(index1,:);
    [~,SE,B0] =  hac(X,Y,'intercept',false,'bandwidth',7,'display','off');
    
    
    -B0(1)./mean(NYISO_d.gasPrice(index2)-B0(1));
    
    SST = sum((Y-mean(Y)).^2);
    SSR = sum((Y - X*B0).^2);
    R2 = 1-SSR/SST;

    NG(i).Info = 'Nat.Gas';
    NG(i).B = B0;
    NG(i).SE = SE;
    NG(i).t = NG(i).B./NG(i).SE;
    NG(i).R2 = R2;
    NG(i).OBS = sum(index1);

end

% Compute counterfactual
B0 = NG(1).B;
NYISO_d.gasPrice_cft = NYISO_d.gasPrice-X0(:,1)*B0(1);
NYISO2 = retime(NYISO_d,'hourly','mean');
NYISO.gasPrice_cft = NYISO.gasPrice;
NYISO.gasPrice_cft(1:height(NYISO2)) = NYISO2.gasPrice_cft;
NYISO.gasPrice_cft(height(NYISO2)+1:end) = nan;
NYISO.gasPrice_cft = fillmissing(NYISO.gasPrice_cft,'previous');
clear NYISO2

% Figure
C = linspecer(6);
figure(1)
plot(NYISO.Time,NYISO.gasPrice,'color',C(2,:),'linewidth',1.1)
hold on
bb = find(NYISO.Time>=datetime(2019,1,1) & NYISO.Time<datetime(2020,3,1));
plot(NYISO.Time(bb)+days(365),NYISO.gasPrice(bb),'--','color',C(6,:),'linewidth',0.3)
plot(NYISO.Time,NYISO.gasPrice_cft,'.-','color',C(1,:),'linewidth',1)
plot([datetime(2020,3,1) datetime(2020,3,1)],[0 50],':k','color',C(4,:),'linewidth',2)
plot(NYISO.Time,NYISO.gasPrice,'color',C(2,:),'linewidth',1.1)
hold off
xlim([datetime(2020,1,1) datetime(2021,2,28)])
ylim([0 4])
legend('Observed prices','Previous-year prices','Counterfactual prices','1st COVID case','location','north')
set(gca,'FontSize',14)
ylabel('T6 NY Natural Gas Price ($/MMBtu)')
saveas(1,['RESULTS/FIGURES/plot_NG.eps'],'epsc')

% Regression table
clear TABLEVALS
ii=1;
for i = 1:2
    j=1;   
    for jj=1:3
        TABLEVALS{j,ii} = ['$',num2str(NG(i).B(jj),'%0.2f'),'$'];
        TABLEVALS{j,ii+1} = ['$(',num2str(NG(i).SE(jj),'%0.2f'),')$'];
        j=j+1;
    end    
    TABLEVALS{j,ii} = ['$',num2str(NG(i).OBS,'%0.0f'),'$'];
    TABLEVALS{j+1,ii} = ['$',num2str(NG(i).R2,'%0.2f'),'$'];
    ii = ii+2;
end
TABLEVALS

ROWNAMES = {'Date $\geq$ 2020-03-01','Temp $\leq$ 15F','Temperature'};
ROWNAMES{end+1} ='Obs.';
ROWNAMES{end+1} ='$R^2$';
COLNAMES = {' ',' ',' '};
TABLE = ['\begin{tabular*}{1\hsize}{@{\hskip\tabcolsep\extracolsep\fill}l*{5}{rrrr}}',...
    ' \hline  \hline ',...
    '& \multicolumn{2}{c}{2019-2021}  & \multicolumn{2}{c}{2016-2021}     \\',...
    ' \hline ',...
    ];
for j=1:5
    TABLE = [TABLE,...
        ROWNAMES{j},' & ',TABLEVALS{j,1},' & ',TABLEVALS{j,2},' & ',TABLEVALS{j,3},' & ',TABLEVALS{j,4},' \\ ']; 
    if j==3
         TABLE = [TABLE,' \hline ',]; 
    end
end

TABLE = [TABLE,...
    ' \hline \end{tabular*}'];

fileID = fopen(['RESULTS/TABLES/table_NG.tex'],'w');
fprintf(fileID,'%s',TABLE);
fclose(fileID);

%% Nuclear generation
load(fullfile(project_root,'data','NUKE.mat'))

NUKE.three_mile_island_1{end+1,1} = 0;
NUKE.three_mile_island_1{end,2} = {'9/20/2019'};
NUKE.three_mile_island_1{end,3} = {'Reactor defueled for permanent shutdown'};
NUKE.three_mile_island_1{end,4} = {'*'};
NUKE.three_mile_island_1{end,5} = {'1'};
NUKE.three_mile_island_1.Time(end) = datetime(2021,05,19);

NUKE.three_mile_island_1 = retime(NUKE.three_mile_island_1, 'hourly','previous');
NUKE.fitzpatrick = retime(NUKE.fitzpatrick, 'hourly','previous');
NUKE.ginna = retime(NUKE.ginna, 'hourly','previous');
NUKE.indian_point_2 = retime(NUKE.indian_point_2, 'hourly','previous');
NUKE.indian_point_3 = retime(NUKE.indian_point_3, 'hourly','previous');
NUKE.nine_mile_point_1 = retime(NUKE.nine_mile_point_1, 'hourly','previous');
NUKE.nine_mile_point_2 = retime(NUKE.nine_mile_point_2, 'hourly','previous');

idx = find(NUKE.three_mile_island_1.Time>=min(NYISO.Time) & NUKE.three_mile_island_1.Time<=max(NYISO.Time));
idx = [idx;idx(end)+1];


fp_REFUELING = contains(lower((NUKE.fitzpatrick.comment)),'refueling outage') & NUKE.fitzpatrick.power==0;
g_REFUELING = contains(lower((NUKE.ginna.comment)),'refueling outage') & NUKE.ginna.power==0;
ip2_REFUELING = contains(lower((NUKE.indian_point_2.comment)),'refueling outage') & NUKE.indian_point_2.power==0;
ip3_REFUELING = contains(lower((NUKE.indian_point_3.comment)),'refueling outage') & NUKE.indian_point_3.power==0;
nmp1_REFUELING = contains(lower((NUKE.nine_mile_point_1.comment)),'refueling outage') & NUKE.nine_mile_point_1.power==0;
nmp2_REFUELING = contains(lower((NUKE.nine_mile_point_2.comment)),'refueling outage') & NUKE.nine_mile_point_2.power==0;
tmi1_REFUELING = contains(lower((NUKE.three_mile_island_1.comment)),'refueling outage') & NUKE.three_mile_island_1.power==0;

REFUELING = (fp_REFUELING + g_REFUELING + ip2_REFUELING + ip3_REFUELING + nmp1_REFUELING + nmp2_REFUELING + tmi1_REFUELING)>=1;

NYISO.REFUELING = REFUELING(idx);
mean(NYISO.REFUELING)

NYISO.ACAP_FP = NUKE.fitzpatrick{idx,1};
NYISO.ACAP_G = NUKE.ginna{idx,1};
NYISO.ACAP_IP2 = NUKE.indian_point_2{idx,1};
NYISO.ACAP_IP3 = NUKE.indian_point_3{idx,1};
NYISO.ACAP_NMP1 = NUKE.nine_mile_point_1{idx,1};
NYISO.ACAP_NMP2 = NUKE.nine_mile_point_2{idx,1};
NYISO.ACAP_TMI1 = NUKE.three_mile_island_1{idx,1};

clear REFUELING idx fp_REFUELING g_REFUELING ip2_REFUELING ip3_REFUELING nmp1_REFUELING nmp2_REFUELING tmi1_REFUELING;

%   Previous assumption, assuming no outage at all. However, it does not make
% sense since plants have to be refueled every 24 months.
% Nuke_c = NYISO.nuclear;
% addnuke = linspace(1-0.99,1-0.7,hours(datetime(2020,4,30,19,30,00)-datetime(2020,3,18)))'*1020;
% idx = find(NYISO.Time<datetime(2020,4,30,19,30,00) & NYISO.Time>=datetime(2020,3,18));
% Nuke_c(idx) = NYISO.nuclear(idx) + addnuke;
% 
% idx = find(NYISO.Time<datetime(2020,5,1,02,30,00) & NYISO.Time>=datetime(2020,4,30,18,30,00));
% check = NYISO.nuclear(idx);
% addnuke = 306 -cumsum(check(2:end)-check(1:end-1));
% Nuke_c(idx(2:end)) = Nuke_c(idx(2:end)) + addnuke;
% 
% idx = find(NYISO.Time>=datetime(2020,5,1,02,30,00));
% Nuke_c(idx) = Nuke_c(idx) + 1020;

%   Counterfactual assumption
%NUKE.indian_point_2: Last refueling from March 19 to April 24, 2018. 
%NUKE.indian_point_2: Defueling procedure began on March 18, 2020.
% We hence assume that 0 power available through March 18 to April 23,
% 2020, then back to full power.

Nuke_c = NYISO.nuclear;
idx = find(NYISO.Time<datetime(2020,4,23) & NYISO.Time>=datetime(2020,3,18));
Nuke_c(idx) = NYISO.nuclear(idx) - (NYISO.ACAP_IP2(idx)/100)*1020;
idx = find(NYISO.Time>=datetime(2020,4,24));
plot(NYISO.Time(idx),NUKE.indian_point_2.power(idx))

Nuke_c(idx) = NYISO.nuclear(idx) + (1-NYISO.ACAP_IP2(idx)/100)*1020;

index1 = NYISO.Time >= datetime(2020,01,01) & NYISO.Time < datetime(2021,03,01);
index2 = NYISO.Time >= datetime(2019,01,01) & NYISO.Time < datetime(2020,03,01);

plot(NYISO.Time(index1),NYISO.nuclear(index1),'color',C(2,:),'linewidth',1.1)
hold on
plot(NYISO.Time(index2)+days(365),NYISO.nuclear(index2),'--','color',C(6,:),'linewidth',0.3)
plot(NYISO.Time(index1),Nuke_c(index1),'-.','color',C(1,:),'linewidth',1.1)
plot([datetime(2020,3,1) datetime(2020,3,1)],[0 6000],':k','color',C(4,:),'linewidth',2)
plot(NYISO.Time(index1),NYISO.nuclear(index1),'color',C(2,:),'linewidth',1.1)
hold off
xlim([datetime(2020,01,01) datetime(2021,03,01)])
ylim([2500 6000])
legend('Observed nuclear generation','Observed (previous year)','Counterfactual','1st COVID case','location','best')
set(gca,'FontSize',14)
ylabel('Nuclear generation (MWh)')
saveas(1,['RESULTS/FIGURES/plot_NUKE.eps'],'epsc')

% Don't erase what follows.
% Refueling outages of power plants in the US
%Indian point 2 - 1020MW - retired on April 30, 2020: https://www.powermag.com/indian-point-unit-2-will-shut-down-april-30/
%From March 18 to April 30, Indian Point 2 goes from 1020MW to 70% of that. Then shuts down permanently.
    
% Feb 13, 2020
% Nine Mile Point 2 94      COASTDOWN TO REFUELING OUTAGE        
% 
% March 4, 2020
% Nine Mile Point 2 88      COASTDOWN TO REFUELING OUTAGE
% Nine Mile Point 2 0   3/4/2020    MANUAL REACTOR TRIP - SEE EN# 54562 *   1
% 
% March 18, 2020
% Indian Point 2    99      COASTDOWN TO DEFUELING  *
% 
% March 28, 2020
% Ginna 98      COASTDOWN TO REFUELING OUTAGE   *   
% Indian Point 2    91      COASTDOWN TO DEFUELING  *   
% Nine Mile Point 2 0   3/4/2020    REFUELING OUTAGE
% 
% April 03, 2020
% Indian Point 2    87      COASTDOWN TO DEFUELING      
% Nine Mile Point 2 18      NOT SYNCED TO GRID  *   
% Ginna 94      COASTDOWN TO REFUELING OUTAGE   *
% 
% April 07, 2020
% Ginna 0   4/5/2020    REFUELING OUTAGE    *   
% Indian Point 2    84      COASTDOWN TO DEFUELING      
% Nine Mile Point 2 55      HOLDING FOR TESTING
% 
% April 30, 2020
% Indian Point 2    70      COASTDOWN TO DEFUELING
% Ginna 0   4/5/2020    REFUELING OUTAGE
% Nine Mile Point 1 100             
% Nine Mile Point 2 100 
% 
% May 1, 2020
% Ginna 0   4/5/2020    REFUELING OUTAGE
% Indian Point 2    0   4/30/2020   SHUTDOWN FOR PERMANENT DEFUELING    *
%September: Fitzpatrick

%% Forecast errors
%1. market size: absolute errors have increased
%2. bias: negative bias
%3. variance: increased variance
%4. Counterfactual: fourier basis for mean and variance
% Everything is stored in structure FERR.
%
% Let denote forecast errors by Y_i(t), where i denotes an hourly
% observation and t is 3-dimensional time index [0,24]x[0,24*7]x[0,24*365].
%
% Specify the model as
% Y_i(t) = mu(t) + epsi_i(t)
% epsi_i(t) = sigma(t)*z_i(t),
%
% where z_i(t) is a idiosyncratic shock, same distribution across i and t,
%
% Let mu(t) and sigma(t) be smooth function of t, with 3 main "seasonality
% components" (fourier decomposition) for hours of the day (0,24), days of the week (0,24*7), and
% days of the year (0,24*365).

X_netload = NYISO.rlze - NYISO.nuclear - NYISO.wind - NYISO.otherRenewables;
X_netfload = NYISO.fcst - NYISO.nuclear - NYISO.wind - NYISO.otherRenewables;
X_netcload = NYISO.cfct - NYISO.nuclear - NYISO.wind - NYISO.otherRenewables;
X_gasPrice = NYISO.gasPrice;
X_gasPrice_HH = NYISO.gasPrice_HH;

% Create fix effect dummies
X_hour = dummyvar(hour(NYISO.Time)+1);   X_hour(:,1) = [];
X_wday = dummyvar(weekday(NYISO.Time));  X_wday(:,1) = [];
X_month = dummyvar(month(NYISO.Time));   X_month(:,1) = [];
X_week = dummyvar(week(NYISO.Time));   X_week(:,1) = [];
X_holidays = dummyvar(NYISO.holidays+1); X_holidays(:,1) = [];

zone_name = 'nyiso';

Y = NYISO.ferr;
index = NYISO.Time >= datetime(2016,01,01) & NYISO.Time < datetime(2020,01,01); %
index1 = NYISO.Time >= datetime(2020,01,01) & NYISO.Time < datetime(2020,03,01); %testing sample
index2 = NYISO.Time >= datetime(2019,01,01) & NYISO.Time < datetime(2021,03,01); %2018-2021
index3 = NYISO.Time >= datetime(2020,01,01) & NYISO.Time < datetime(2021,03,01); %2020
index4 = NYISO.Time >= datetime(2021,01,01) & NYISO.Time < datetime(2021,03,01); %2021
index(isnan(Y)) = 0;
index1(isnan(Y)) = 0;
index2(isnan(Y)) = 0;
index3(isnan(Y)) = 0;
index4(isnan(Y)) = 0;
n = sum(index);

nanmean(abs(NYISO.ferr(index2)))

X_year = dummyvar(year(NYISO.Time)-min(year(NYISO.Time))+1);   X_year(:,1) = [];
X_2020 = year(NYISO.Time)==2020;
X_2021 = year(NYISO.Time)==2021;
X_march = [NYISO.Time>=datetime(2020,3,1) & NYISO.Time<=datetime(2020,3,15),NYISO.Time>datetime(2020,3,15) & NYISO.Time<=datetime(2020,3,22),NYISO.Time>datetime(2020,3,22) & NYISO.Time<datetime(2020,4,1)];


X_datetime = [X_2020,X_month(:,1).*repmat(X_2020,1,1),X_march,X_month(:,3:end).*repmat(X_2020,1,9),X_2021,X_month(:,1).*repmat(X_2021,1,1),X_month(:,1:end), ...
    X_hour,X_wday,X_holidays,... 
    (65-WEATHER.kalb.temperature).*(65>WEATHER.kalb.temperature),(WEATHER.kalb.temperature-65).*(65<WEATHER.kalb.temperature),...    
    WEATHER.kalb{:,[9 10 11 12 13 18 19]}]; %snow cloudy windy drizzle rain fair fog


[B,BINT,~,~,STATS] =  regress(abs(NYISO.ferr(index2)),[X_datetime(index2,:),ones(sum(index2),1)]);
BINT(1:16,:)
[B,BINT,~,~,STATS] =  regress(NYISO.ferr(index2),[X_datetime(index2,:),ones(sum(index2),1)]);
BINT(1:16,:)

%Absolute errors
Y = abs(NYISO.ferr);
[EstCoeffCov,SE,Bhat] =  hac(X_datetime(index2,:),Y(index2),'intercept',true,'bandwidth',24*1,'display','off');
Bhat = [Bhat(2:end);Bhat(1)];
SE = [SE(2:end);SE(1)];
table([Bhat(1:14);nan;Bhat(15:end)],[SE(1:14);nan;SE(15:end)])
SST = sum((Y(index2)-mean(Y(index2))).^2);
SSR = sum((Y(index2) - [X_datetime(index2,:),ones(sum(index2),1)]*Bhat).^2);
R2 = 1-SSR/SST;

FERR(1).Info = 'Abs.Errors';
FERR(1).B = Bhat;
FERR(1).SE = SE;
FERR(1).t = FERR(1).B./FERR(1).SE;
FERR(1).R2 = R2;
FERR(1).OBS = sum(index2);
FERR(1).MSE = SSR/sum(index2);

% TABLE_REG_DAM.B(:,zone) = B(2:5,1);
% TABLE_REG_DAM.SE(:,zone) = SE(2:5,1);
% TABLE_REG_DAM.OBS(:,zone) = length(Y(bb));
% TABLE_REG_DAM.COV(:,zone) = size(X(bb,:),2);
% TABLE_REG_DAM.R2(:,zone) = STATS(1);
% TABLE_REG_DAM.MSE0(:,zone) = sqrt(mean((Y_prices(bb)-exp(X0*B)).^2));
% %TABLE_REG_DAM.MSE1(:,zone) = sqrt(mean((Y_prices(b1)-exp(X1*B)).^2));
% TABLE_REG_DAM.MAE0(:,zone) = mean(abs(Y_prices(bb)-exp(X0*B))./Y_prices(bb));

figure(1)
plot([FERR(1).B(1:15)])
hold on
plot([FERR(1).B(1:15)] + (1.96*[FERR(1).SE(1:15)]))
plot([FERR(1).B(1:15)] - (1.96*[FERR(1).SE(1:15)]))
hold off

%Errors
Y = NYISO.ferr;
[EstCoeffCov,SE,Bhat] =  hac(X_datetime(index2,:),Y(index2),'intercept',true,'bandwidth',24*1,'display','off');
Bhat = [Bhat(2:end);Bhat(1)];
SE = [SE(2:end);SE(1)];
table([Bhat(1:14);nan;Bhat(15:end)],[SE(1:14);nan;SE(15:end)])
SST = sum((Y(index2)-mean(Y(index2))).^2);
SSR = sum((Y(index2) - [X_datetime(index2,:),ones(sum(index2),1)]*Bhat).^2);
R2 = 1-SSR/SST;

FERR(2).Info = 'Errors';
FERR(2).B = Bhat;
FERR(2).SE = SE;
FERR(2).t = FERR(2).B./FERR(2).SE;
FERR(2).R2 = R2;
FERR(2).OBS = sum(index2);
FERR(2).MSE = SSR/sum(index2);

figure(2)
plot([FERR(2).B(1:15)])
hold on
plot([FERR(2).B(1:15)] + (1.96*[FERR(2).SE(1:15)]))
plot([FERR(2).B(1:15)] - (1.96*[FERR(2).SE(1:15)]))
hold off

%En fait il faut prendre la variance estimée ici!
%Variance of errors
U = NYISO.ferr - [X_datetime(:,:),ones(length(NYISO.ferr),1)]*FERR(2).B;

%Bootstrapping days -- block-bootstrap HAC-robust SEs w/ Poisson
% Note: here, we bootstrap both steps, 1. linear regression on the mean,
% then 2. exponential regression on squared residuals. We compute the
% bootstrapped pvalues for H0: exp(gamma)=1. These pvalues are HAC robust
% with 24 hours serial correlation.
TIME = NYISO.Time(index2) - hours(hour(NYISO.Time(index2)));
LIST = unique(NYISO.Time(index2) - hours(hour(NYISO.Time(index2))));
J = length(LIST);
Bhat_b = nan(size([X_datetime(:,:)],2),1000); 
XX = X_datetime(index2,:);
YY = U(index2).^2;
idx = find(index2==1);

for bb=1:1000 %bootstrap loop
idx_b= randi(J,J,1);
[a,b] = ismember(LIST(idx_b),TIME);
for j=1:(23) %autocorrelation robust
b = [b,b(:,end)+1];
end
idx_b = b(:);
idx_b = idx_b(1:sum(index2));
idx_b = idx(idx_b);

%warning of rank defficiency will prompt -- no worries, dummies w/o
%observations (due to resampling) are automatically discarded from estimation in glmfit.

Bhat =  regress(NYISO.ferr(idx_b),[X_datetime(idx_b,:),ones(length(idx_b),1)]);
YYb = (NYISO.ferr(idx_b) - [X_datetime(idx_b,:),ones(length(idx_b),1)]*Bhat).^2;

[Bhat,~,~] = glmfit(X_datetime(idx_b,:),YYb,'poisson');
Bhat_b(:,bb) = Bhat(2:end);
end

%Main estimate
[Bhat,dev,stats] = glmfit(XX(:,:),YY(:),'poisson');
SST = sum((YY-mean(YY)).^2);
SSR = sum((YY - exp([ones(sum(index2),1),X_datetime(index2,:)]*Bhat)).^2);
R2 = 1-SSR/SST;
Bhat = Bhat(2:end);

%P-values
PVAL = linspace(0,1,10000);
IC = quantile((Bhat_b-mean(Bhat_b,2) + Bhat)',PVAL)';
[a,b] = min(abs(IC)');
PVAL = PVAL(b)';
PVAL(PVAL>0.5) = 1-PVAL(PVAL>0.5);
PVAL = PVAL*2;

FERR(3).Info = 'Variance';
FERR(3).B = exp(Bhat);
FERR(3).SE = PVAL; %those are PVAL not SE, but we make the struct consistent
FERR(3).R2 = R2;
FERR(3).OBS = sum(index2);
FERR(3).MSE = SSR/sum(index2);
table(FERR(3).B(1:15),FERR(3).SE(1:15))


%% Forecast errors regression - figures
Time = [datetime(2020,1,1,0,30,0),datetime(2020,1,15,0,30,0),datetime(2020,2,15,0,30,0),datetime(2020,3,7,0,30,0),datetime(2020,3,19,0,30,0),datetime(2020,3,28,0,30,0),...
    datetime(2020,4,15,0,30,0),datetime(2020,5,15,0,30,0),datetime(2020,6,15,0,30,0),datetime(2020,7,15,0,30,0),datetime(2020,8,15,0,30,0),datetime(2020,9,15,0,30,0),datetime(2020,10,15,0,30,0),...
    datetime(2020,11,15,0,30,0),datetime(2020,12,15,0,30,0),datetime(2021,1,15,0,30,0),datetime(2021,2,15,0,30,0),datetime(2021,2,29,0,30,0)];


BABS = [0;FERR(1).B(1:16);0];
ICABS_L = [0;FERR(1).B(1:16);0] - (1.96*[0;FERR(1).SE(1:16);0]);
ICABS_U = [0;FERR(1).B(1:16);0] + (1.96*[0;FERR(1).SE(1:16);0]);

BBIAS= [0;FERR(2).B(1:16);0];
ICBIAS_L = [0;FERR(2).B(1:16);0] - (1.96*[0;FERR(2).SE(1:16);0]);
ICBIAS_U = [0;FERR(2).B(1:16);0] + (1.96*[0;FERR(2).SE(1:16);0]);

IC = quantile((Bhat_b-mean(Bhat_b,2) + Bhat)',[0.025 0.975])';
BVAR = [1;FERR(3).B(1:16);1];
ICVAR_L = [1;exp(IC(1:16,1));1];
ICVAR_U = [1;exp(IC(1:16,2));1];

TT = timetable(Time',BABS,ICABS_L,ICABS_U,BBIAS,ICBIAS_L,ICBIAS_U,BVAR,ICVAR_L,ICVAR_U);
TT = retime(TT,'hourly','mean');
TT = fillmissing(TT,'spline');
TT(end,:) = [];

C = linspecer(6);
figure(1)
plot(TT.Time,TT.BABS,'-','color',C(2,:),'linewidth',1.5)
hold on
patch([TT.Time(:); flipud(TT.Time(:))]', [TT.ICABS_U; flipud(TT.ICABS_L)]', 'b', 'FaceAlpha',0.1, 'EdgeColor','none')   % Plot ‘patch’ Object, No Edges
plot(Time(2:end-1),BABS(2:end-1),'d','color',C(1,:),'linewidth',1)
xline(datetime(2020,3,1),'--','color',C(4,:),'linewidth',1.1)
xline(datetime(2020,3,23),'--','color',C(5,:),'linewidth',1.1)
yline(1)
hold off
ylim([-200 800])
xlim([datetime(2020,1,15) datetime(2021,2,15)])
legend('Spline interpolation','95% Confidence Interval','Point estimates','1st reported COVID-19 case in NY','Lockdown') %'Day-ahead prices','
set(gca,'FontSize',18)
set(legend,'Location','northeast')
ylabel('Absolute forecast errors (ATE, MWh)')
saveas(1,['RESULTS/FIGURES/plot_FERR_ABS.eps'],'epsc')


figure(2)
plot(TT.Time,TT.BBIAS,'-','color',C(2,:),'linewidth',1.5)
hold on
patch([TT.Time(:); flipud(TT.Time(:))]', [TT.ICBIAS_U; flipud(TT.ICBIAS_L)]', 'b', 'FaceAlpha',0.1, 'EdgeColor','none')   % Plot ‘patch’ Object, No Edges
plot(Time(2:end-1),BBIAS(2:end-1),'d','color',C(1,:),'linewidth',1)
xline(datetime(2020,3,1),'--','color',C(4,:),'linewidth',1.1)
xline(datetime(2020,3,23),'--','color',C(5,:),'linewidth',1.1)
yline(1)
hold off
xlim([datetime(2020,1,15) datetime(2021,2,15)])
legend('Spline interpolation','95% Confidence Interval','Point estimates','1st reported COVID-19 case in NY','Lockdown') %'Day-ahead prices','
set(gca,'FontSize',18)
set(legend,'Location','southeast')
ylabel('Forecast errors (ATE, MWh)')
ylim([-1120 400])
saveas(2,['RESULTS/FIGURES/plot_FERR_BIA.eps'],'epsc')

figure(3)
plot(TT.Time,sqrt(TT.BVAR),'-','color',C(2,:),'linewidth',1.5)
hold on
patch([TT.Time(:); flipud(TT.Time(:))]', [sqrt(TT.ICVAR_U); flipud(sqrt(TT.ICVAR_L))]', 'b', 'FaceAlpha',0.1, 'EdgeColor','none')   % Plot ‘patch’ Object, No Edges
plot(Time(2:end-1),sqrt(BVAR(2:end-1)),'d','color',C(1,:),'linewidth',1)
xline(datetime(2020,3,1),'--','color',C(4,:),'linewidth',1.1)
xline(datetime(2020,3,23),'--','color',C(5,:),'linewidth',1.1)
yline(1)
hold off
xlim([datetime(2020,1,15) datetime(2021,2,15)])
legend('Spline interpolation','95% Confidence Interval','Point estimates','1st reported COVID-19 case in NY','Lockdown') %'Day-ahead prices','
set(gca,'FontSize',18)
set(legend,'Location','northeast')
ylabel('Std. of forecast errors (ATE)')
ylim([0.3 4])
saveas(3,['RESULTS/FIGURES/plot_FERR_VAR.eps'],'epsc')


%% New counterfactual F.errs
clear Y YY XX X_datetime Bhat SE R2 SST SSR dev stats LIST J TIME EstCoeffCov

XX = [X_2020.*(sum(X_month,2)==0),X_month(:,1).*repmat(X_2020,1,1),X_march,X_month(:,3:end).*repmat(X_2020,1,9),X_2021.*(sum(X_month,2)==0),X_month(:,1).*repmat(X_2021,1,1)];
NYISO.FERR_mean = XX*FERR(2).B(1:16); %.*repmat(FERR(2).B(1:15)',size(X_2020,1),1);
NYISO.FERR_var = XX*FERR(3).B(1:16); 

NYISO.FERR_mean = zeros(size(NYISO.ferr));
NYISO.FERR_var = ones(size(NYISO.ferr));

index5 = NYISO.Time >= datetime(2020,01,01) & NYISO.Time < datetime(2021,03,01); %2021
index6 = NYISO.Time >= datetime(2016,01,01) & NYISO.Time < datetime(2020,03,01); %2021

NYISO.FERR_mean(index5) = TT.BBIAS;
NYISO.FERR_var(index5) = TT.BVAR;

%NYISO.FERR_mean(index6) = 0;
%NYISO.FERR_var(index6) = 1;
NYISO_m = NYISO;

spar = 0.001
plot(smooth(NYISO_m.FERR_mean(index5),spar,'loess'))
plot(smooth(NYISO_m.FERR_var(index5),spar,'loess'))

plot(NYISO.Time(index5),(NYISO.ferr(index5) - smooth(NYISO_m.FERR_mean(index5),spar,'loess'))./smooth(sqrt(NYISO_m.FERR_var(index5)),spar,'loess'))
hold on
plot(NYISO.Time(index5),(NYISO.ferr(index5)))
hold off

plot(NYISO.Time(index5),cumsum(abs(NYISO.ferr(index5))))
hold on
plot(NYISO.Time(index5),cumsum(abs((NYISO.ferr(index5) - smooth(NYISO_m.FERR_mean(index5),spar,'loess'))./sqrt(smooth(NYISO_m.FERR_var(index5),spar,'loess')))))
hold off

ferr_hat = (NYISO.ferr(index5) - smooth(NYISO.FERR_mean(index5),spar,'loess'))./sqrt(smooth(NYISO.FERR_var(index5),spar,'loess'));

FERR(5).info = 'Contrefactual forecast errors';
FERR(5).time = NYISO.Time(index5);
FERR(5).cft = ferr_hat;

C = linspecer(6);

index6 = NYISO.Time >= datetime(2019,01,01) & NYISO.Time < datetime(2020,01,01); %2021
index7 = NYISO.Time >= datetime(2018,01,01) & NYISO.Time < datetime(2019,01,01); %2021
index8 = NYISO.Time >= datetime(2020,01,01) & NYISO.Time < datetime(2021,03,01); %2021

% Density of actual, past, and counterfactual forecast errors
xi = linspace(-3000,3000,10000);
f0 = ksdensity(ferr_hat(1:end),xi);
f1 = ksdensity(NYISO.ferr(index8),xi);
f2 = ksdensity(NYISO.ferr(index6),xi);
%f3 = ksdensity(NYISO.ferr(index7),xi);
figure(1)
plot(xi,f1,'-','color',C(2,:),'linewidth',1.5)
yticklabels('manual')
hold on
plot(xi,f0,'-','color',C(1,:),'linewidth',1.5)
plot(xi,f2,'-','color',C(3,:),'linewidth',1.5)
xline(0)
hold off
xlim([-3000 3000])
legend('Actual (2020-2021)','Counterfactual (2020-2021)','Actual (2019)') %'Day-ahead prices','
set(gca,'FontSize',14)
set(legend,'Location','best')
ylabel('Density')
xlabel('Forecast errors (MWh)')
saveas(1,['RESULTS/FIGURES/plot_DENS_FERR.eps'],'epsc')


figure(2)
idx = find(index5==1);
idx2 = find(index3==1);
trim = 24; %trim first and last day 
plot(NYISO.Time(idx2(1+trim:end-trim)),smooth(NYISO.ferr(idx2(1+trim:end-trim)),24*5),'-','color',C(2,:),'linewidth',1.5)
hold on
plot(NYISO.Time(index5),smooth(ferr_hat,24*5),'-','color',C(1,:),'linewidth',1.5)
plot([datetime(2020,3,1) datetime(2020,3,1)],[-1500 1500],'--','color',C(4,:),'linewidth',1.1)
plot([datetime(2020,1,1) datetime(2021,3,1)],[0 0],':k','linewidth',1)
plot(NYISO.Time(index5),smooth(NYISO.ferr(index5),24*5),'-','color',C(2,:),'linewidth',1.5)
ylim([-1500 1500])
xlim([datetime(2020,1,1) datetime(2021,3,1)])
% plot(NYISO.Time(idx(1+trim:end-trim)),NYISO.ferr(idx(1+trim:end-trim)),':','color',C(2,:),'linewidth',0.1)
% plot(NYISO.Time(idx(1+trim:end-trim)),ferr_hat(1+trim:end-trim),':','color',C(1,:),'linewidth',0.1)
% plot(NYISO.Time(idx(1+trim:end-trim)),smooth(NYISO.ferr(idx(1+trim:end-trim)),24*5),'-','color',C(2,:),'linewidth',1.5)
% plot(NYISO.Time(idx(1+trim:end-trim)),smooth(ferr_hat(1+trim:end-trim),24*5),'-','color',C(1,:),'linewidth',1.5)
hold off
legend('Actual','Counterfactual','1st reported COVID-19 case in NY') %'Day-ahead prices','
set(gca,'FontSize',14)
set(legend,'Location','northeast')
ylabel('Forecast errors (MWh)')
saveas(2,['RESULTS/FIGURES/plot_CFT_FERR.eps'],'epsc')


%% Regression results forecast errors
clear TABLEVALS
ii=1;
for i = 1:3 %1:size(TABLE_REG_DAM2.B,2)
    j=1;   
    for jj=1:16
        TABLEVALS{j,ii} = ['$',num2str(FERR(i).B(jj),'%0.2f'),'$'];
        if i~=3
        TABLEVALS{j,ii+1} = ['$(',num2str(FERR(i).SE(jj),'%0.2f'),')$'];
        else
          TABLEVALS{j,ii+1} = ['$[',num2str(FERR(i).SE(jj),'%0.2f'),']$'];  
        end
        j=j+1;
    end    
    TABLEVALS{j,ii} = ['$',num2str(FERR(i).OBS,'%0.0f'),'$'];
    TABLEVALS{j+1,ii} = ['$',num2str(FERR(i).R2,'%0.2f'),'$'];
    ii = ii+2;
end
TABLEVALS

%ROWNAMES = cellstr(datestr(unique(NYISO.Time(index3) - day(NYISO.Time(index3)) +day(1) - hours(hour(NYISO.Time(index3)))),'yyyy-mmm'));
ROWNAMES = {'2020-Jan','2020-Feb','2020-March (1-15)','2020-Mar (16-22)','2020-Mar (23-31)','2020-Apr','2020-May','2020-Jun','2020-Jul','2020-Aug','2020-Sep','2020-Oct','2020-Nov','2020-Dec','2021-Jan','2021-Feb'};
ROWNAMES{end+1} ='Obs.';
ROWNAMES{end+1} ='$R^2$';
COLNAMES = {' ',' ',' '};
TABLE = ['\begin{tabular*}{1\hsize}{@{\hskip\tabcolsep\extracolsep\fill}l*{7}{rrrrrr}}',...
    ' \hline  \hline ',...
    '& \multicolumn{2}{c}{Abs.Ferr.}  & \multicolumn{2}{c}{Ferr.} & \multicolumn{2}{c}{Var.}     \\',...
    ' \hline ',...
    ];
for j=1:17
    TABLE = [TABLE,...
        ROWNAMES{j},' & ',TABLEVALS{j,1},' & ',TABLEVALS{j,2},' & ',TABLEVALS{j,3},' & ',TABLEVALS{j,4},' & ',TABLEVALS{j,5},' & ',TABLEVALS{j,6},' \\ ']; 
    if j==16
         TABLE = [TABLE,' \hline ',]; 
    end
end

TABLE = [TABLE,...
    ' \hline \end{tabular*}'];

fileID = fopen(['RESULTS/TABLES/table_REGFERR.tex'],'w');
fprintf(fileID,'%s',TABLE);
fclose(fileID);



%% Day-ahead market
WEATHER.kalb_min = retime(WEATHER.kalb_d_min,'hourly','mean');
WEATHER.kalb_min{45241+1:45241+23,1:end} = nan;
WEATHER.kalb_min.Time(45241+1:45241+23) = (WEATHER.kalb_min.Time(45241)+hours(1:23))';
WEATHER.kalb_min = fillmissing(WEATHER.kalb_min,'previous');

clc
Y = PRICES.(zone_name).dam;
X_nuclear = NYISO.nuclear/1000;

index = NYISO.Time >= datetime(2016,01,01) & NYISO.Time < datetime(2020,01,01);
index1 = NYISO.Time >= datetime(2020,01,01) & NYISO.Time < datetime(2020,03,01);
index2 = NYISO.Time >= datetime(2016,01,01) & NYISO.Time < datetime(2021,03,01);
index(isnan(Y)) = 0;
index1(isnan(Y)) = 0;
index2(isnan(Y)) = 0;
n = sum(index);


%Refueling calendar as IV for nuke output? Identified graphically taking only large
%persistent drops of nuclear output.
%plot(NYISO.Time,NYISO.nuclear)
idx = find( (NYISO.Time >= datetime(2016,03,07) & NYISO.Time < datetime(2016,07,09)) ...
    | (NYISO.Time >= datetime(2017,01,12) & NYISO.Time < datetime(2017,02,22)) ...
    | (NYISO.Time >= datetime(2017,03,13) & NYISO.Time < datetime(2017,05,17)) ...
    | (NYISO.Time >= datetime(2017,06,12) & NYISO.Time < datetime(2017,06,22)) ...
    | (NYISO.Time >= datetime(2018,02,16) & NYISO.Time < datetime(2018,02,28)) ...
    | (NYISO.Time >= datetime(2018,03,18) & NYISO.Time < datetime(2018,05,20)) ...
    | (NYISO.Time >= datetime(2018,09,07) & NYISO.Time < datetime(2018,10,11)) ...
    | (NYISO.Time >= datetime(2018,11,21) & NYISO.Time < datetime(2018,11,11)) ...
    | (NYISO.Time >= datetime(2019,03,10) & NYISO.Time < datetime(2019,05,06)) ...
    | (NYISO.Time >= datetime(2020,01,31) & NYISO.Time < datetime(2020,02,13)) ...
    | (NYISO.Time >= datetime(2020,03,04) & NYISO.Time < datetime(2020,05,29)) ...
    | (NYISO.Time >= datetime(2020,09,12) & NYISO.Time < datetime(2020,10,10)));
NYISO.Refuel = zeros(height(NYISO),1);
NYISO.Refuel(idx) = 1;

NYISO.NUKECAP = (NYISO.ACAP_IP2+NYISO.ACAP_IP3+NYISO.ACAP_G+NYISO.ACAP_FP+NYISO.ACAP_NMP1+NYISO.ACAP_NMP2)/6;

X = [(X_netfload/1000),X_gasPrice,X_nuclear, X_hour, X_wday,X_month,X_holidays];

for i=1:4
    % Many possible IVs: similar results.
    if i==1
        Z = X;        
    elseif i==2
        Z = [(WEATHER.kalb.temperature-65).^2/mean((WEATHER.kalb.temperature-65).^2),X_gasPrice_HH,X_nuclear, X_hour, X_wday,X_month,X_holidays];        
    elseif i==3
        Z = [(WEATHER.kalb.temperature-65).^2/mean((WEATHER.kalb.temperature-65).^2),X_gasPrice_HH,NYISO.NUKECAP, X_hour, X_wday,X_month,X_holidays];
    else
        Z = [abs(WEATHER.kalb.temperature-65)/mean(abs(WEATHER.kalb.temperature-65)),X_gasPrice_HH,NYISO.NUKECAP, X_hour, X_wday,X_month,X_holidays];
    end
    %Z = [(WEATHER.kith.temperature-65).^2/mean((WEATHER.kith.temperature-65).^2),X_gasPrice_HH,NYISO.Refuel, X_hour, X_wday,X_month,X_holidays];
    
    YY = Y(index);
    XX = [ones(n,1),X(index,:)];
    ZZ = [ones(n,1),Z(index,:)];
    T = length(YY);
    
    % First-stage
    [B_GMM0,COVB0,B_GMM1,COVB1,B_GMM2,COVB2,Jtest,Jpval] = HAC_GMM(XX(:,2),ZZ,ZZ,1);
    SE_GMM0 = sqrt(diag(COVB0));
    SE_GMM1 = sqrt(diag(COVB1));
    SE_GMM2 = sqrt(diag(COVB2));
    table(B_GMM0,SE_GMM0,B_GMM1,SE_GMM1,B_GMM2,SE_GMM2);
    
    B = B_GMM2; %Two-step optimal HAC-GMM
    SE = SE_GMM2;
    SST = sum((XX(:,2)-mean(XX(:,2))).^2);
    SSR = sum((XX(:,2) - ZZ*B).^2);
    R2 = 1-SSR/SST;
    
    DAM(i).FS(1).Info = 'DAM First-stage: Net demand';
    DAM(i).FS(1).B = B;
    DAM(i).FS(1).SE = SE;
    DAM(i).FS(1).R2 = R2;
    DAM(i).FS(1).OBS = sum(index);
    DAM(i).FS(1).RMSE = sqrt(mean((XX(:,2)- ZZ*B).^2));
    
    [B_GMM0,COVB0,B_GMM1,COVB1,B_GMM2,COVB2,Jtest,Jpval] = HAC_GMM(XX(:,3),ZZ,ZZ,1);
    SE_GMM0 = sqrt(diag(COVB0));
    SE_GMM1 = sqrt(diag(COVB1));
    SE_GMM2 = sqrt(diag(COVB2));
    table(B_GMM0,SE_GMM0,B_GMM1,SE_GMM1,B_GMM2,SE_GMM2);
    
    B = B_GMM2; %Two-step optimal HAC-GMM
    SE = SE_GMM2;
    SST = sum((XX(:,3)-mean(XX(:,3))).^2);
    SSR = sum((XX(:,3) - ZZ*B).^2);
    R2 = 1-SSR/SST;
    
    DAM(i).FS(2).Info = 'DAM First-stage: NG price';
    DAM(i).FS(2).B = B;
    DAM(i).FS(2).SE = SE;
    DAM(i).FS(2).R2 = R2;
    DAM(i).FS(2).OBS = sum(index);
    DAM(i).FS(2).RMSE = sqrt(mean((XX(:,3)- ZZ*B).^2));
    
    [B_GMM0,COVB0,B_GMM1,COVB1,B_GMM2,COVB2,Jtest,Jpval] = HAC_GMM(XX(:,4),ZZ,ZZ,1);
    SE_GMM0 = sqrt(diag(COVB0));
    SE_GMM1 = sqrt(diag(COVB1));
    SE_GMM2 = sqrt(diag(COVB2));
    table(B_GMM0,SE_GMM0,B_GMM1,SE_GMM1,B_GMM2,SE_GMM2);
    
    B = B_GMM2; %Two-step optimal HAC-GMM
    SE = SE_GMM2;
    SST = sum((XX(:,4)-mean(XX(:,4))).^2);
    SSR = sum((XX(:,4) - ZZ*B).^2);
    R2 = 1-SSR/SST;
    
    DAM(i).FS(3).Info = 'DAM First-stage: Nuclear output';
    DAM(i).FS(3).B = B;
    DAM(i).FS(3).SE = SE;
    DAM(i).FS(3).R2 = R2;
    DAM(i).FS(3).OBS = sum(index);
    DAM(i).FS(3).RMSE = sqrt(mean((XX(:,4)- ZZ*B).^2));
    
    % Second-stage
    [B_GMM0,COVB0,B_GMM1,COVB1,B_GMM2,COVB2,Jtest,Jpval] = HAC_GMM(YY,XX,ZZ,1);
    SE_GMM0 = sqrt(diag(COVB0));
    SE_GMM1 = sqrt(diag(COVB1));
    SE_GMM2 = sqrt(diag(COVB2));
    table(B_GMM0(2:5),SE_GMM0(2:5),B_GMM1(2:5),SE_GMM1(2:5),B_GMM2(2:5),SE_GMM2(2:5))
    
    B = B_GMM2; %Two-step optimal HAC-GMM
    SE = SE_GMM2;
        
    %mean(abs(Y(index1)- [ones(sum(index1),1),X(index1,:)]*B))./mean(Y(index1))
    
    SST = sum((Y(index)-mean(Y(index))).^2);
    SSR = sum((Y(index) - XX*B).^2);
    R2 = 1-SSR/SST;
    
    
    DAM(i).Info = 'DAM';
    DAM(i).B = B;
    DAM(i).SE = SE; %those are PVAL not SE, but we make the struct consistent
    DAM(i).R2 = R2;
    DAM(i).OBS = sum(index);
    DAM(i).RMSE = sqrt(mean((Y(index)- [ones(sum(index),1),X(index,:)]*B).^2));
     DAM(i).RMSE
    % plug-in bandwidth implies 15 lags for HAC matrix
end


% Figure
C = linspecer(6);
figure(1)
YY_c = Y(index2);
XX_c = [ones(sum(index2),1),X(index2,:)];
semilogy(NYISO.Time(index2),smooth(YY_c,14*24),'-','color',C(2,:),'linewidth',2)
hold on
semilogy(NYISO.Time(index2),smooth(XX_c*DAM(3).B,14*24),':','color',C(1,:),'linewidth',2)
xline(datetime(2020,3,1),'--','color',C(4,:),'linewidth',1.1)
hold off
legend('Observed prices','Predicted prices','1st reported COVID-19 case in NY') %'Day-ahead prices','
set(gca,'FontSize',14)
set(legend,'Location','best')
ylabel('Day-ahead Prices ($/MWh, logscale)')
ylim([0 250])
yticks([10 50 100 150 200])
saveas(1,['RESULTS/FIGURES/plot_DAM_FIT.eps'],'epsc')
    
    
%% Regression results DAM
% Second-stage
clear TABLEVALS
ii=1;
for i = 1:3 %1:size(TABLE_REG_DAM2.B,2)
    j=1;   
    for jj=2:4
        TABLEVALS{j,ii} = ['$',num2str(DAM(i).B(jj),'%0.2f'),'$'];
        TABLEVALS{j,ii+1} = ['$(',num2str(DAM(i).SE(jj),'%0.2f'),')\quad$'];
        j=j+1;
    end    
    TABLEVALS{j,ii} = ['$',num2str(DAM(i).OBS,'%0.0f'),' $'];
    TABLEVALS{j+1,ii} = ['$',num2str(DAM(i).R2,'%0.2f'),'$'];
    ii = ii+2;
end

TABLEVALS
ROWNAMES = {'$\overline{D}-N-R$','$NG$', '$N$'};
ROWNAMES{end+1} ='Obs.';
ROWNAMES{end+1} ='$R^2$';
COLNAMES = {' ',' ',' '};
TABLE = ['\begin{tabular*}{1\hsize}{@{\hskip\tabcolsep\extracolsep\fill}l*{7}{rrrrrr}}',...
    ' \hline  \hline ',...
    '& \multicolumn{2}{c}{GMM (1)}  & \multicolumn{2}{c}{IV-GMM (2)} & \multicolumn{2}{c}{IV-GMM (3)}      \\',...
    ' \hline ',...
    ];
for j=1:5
    TABLE = [TABLE,...
        ROWNAMES{j},' & ',TABLEVALS{j,1},' & ',TABLEVALS{j,2},' & ',TABLEVALS{j,3},' & ',TABLEVALS{j,4},' & ',TABLEVALS{j,5},' & ',TABLEVALS{j,6},' \\ ']; 
    if j==3
         TABLE = [TABLE,' \hline ',]; 
    end
end

TABLE = [TABLE,...
    ' \hline \end{tabular*}'];

fileID = fopen(['RESULTS/TABLES/table_REGDAM.tex'],'w');
fprintf(fileID,'%s',TABLE);
fclose(fileID);

%First-stages
clear TABLEVALS
ii=1;
for i = 1:3 %1:size(TABLE_REG_DAM2.B,2)
    j=1;   
    for jj=2:4
        TABLEVALS{j,ii} = ['$',num2str(DAM(3).FS(i).B(jj),'%0.2f'),'$'];
        TABLEVALS{j,ii+1} = ['$(',num2str(DAM(3).FS(i).SE(jj),'%0.2f'),')\quad$'];
        j=j+1;
    end    
    TABLEVALS{j,ii} = ['$',num2str(DAM(3).FS(i).OBS,'%0.0f'),' $'];
    TABLEVALS{j+1,ii} = ['$',num2str(DAM(3).FS(i).R2,'%0.2f'),'$'];
    ii = ii+2;
end

TABLEVALS
ROWNAMES = {'$(Temp-65)^2$','$NG$ (Henry Hub)', '$Refueling$'};
ROWNAMES{end+1} ='Obs.';
ROWNAMES{end+1} ='$R^2$';
COLNAMES = {' ',' ',' '};
TABLE = ['\begin{tabular*}{1\hsize}{@{\hskip\tabcolsep\extracolsep\fill}l*{7}{rrrrrr}}',...
    ' \hline  \hline ',...
    '& \multicolumn{2}{c}{$\overline{D}-N-R$}  & \multicolumn{2}{c}{$NG$} & \multicolumn{2}{c}{$N$}   \\',...
    ' \hline ',...
    ];
for j=1:5
    TABLE = [TABLE,...
        ROWNAMES{j},' & ',TABLEVALS{j,1},' & ',TABLEVALS{j,2},' & ',TABLEVALS{j,3},' & ',TABLEVALS{j,4},' & ',TABLEVALS{j,5},' & ',TABLEVALS{j,6},' \\ ']; 
    if j==3
         TABLE = [TABLE,' \hline ',]; 
    end
end

TABLE = [TABLE,...
    ' \hline \end{tabular*}'];

fileID = fopen(['RESULTS/TABLES/table_REGDAM_FS.tex'],'w');
fprintf(fileID,'%s',TABLE);
fclose(fileID);


%% RTM
   
index3 = NYISO.Time >= datetime(2020,03,01) & NYISO.Time < datetime(2021,03,01);
index4 = NYISO.Time >= datetime(2020,03,01) & NYISO.Time < datetime(2020,07,01);
Y = PRICES.(zone_name).rtm;


zonen = 'nyc';
for i =1:4
if i == 1
    
X = [PRICES.('nyiso').dam,NYISO.ferr/1000,X_gasPrice, X_hour, X_wday,X_month,X_holidays];
Z=X;
 elseif i == 2
 X = [PRICES.('nyiso').dam,NYISO.ferr/1000,X_gasPrice, X_hour, X_wday,X_month,X_holidays];
 Z = [PRICES.('nyiso').dam,LOAD.(zonen).ferr/1000,X_gasPrice, X_hour, X_wday,X_month,X_holidays];

elseif i == 3
X = [PRICES.('nyiso').dam,(NYISO.ferr<=0).*abs(NYISO.ferr)/1000,(NYISO.ferr>0).*abs(NYISO.ferr)/1000,X_gasPrice, X_hour, X_wday,X_month,X_holidays];
Z = X;
elseif i == 4
X = [PRICES.('nyiso').dam,(NYISO.ferr<=0).*abs(NYISO.ferr)/1000,(NYISO.ferr>0).*abs(NYISO.ferr)/1000,X_gasPrice, X_hour, X_wday,X_month,X_holidays];
Z = [PRICES.('nyiso').dam,(LOAD.(zonen).ferr<=0).*abs(LOAD.(zonen).ferr)/1000,(LOAD.(zonen).ferr>0).*abs(LOAD.(zonen).ferr)/1000,X_gasPrice, X_hour, X_wday,X_month,X_holidays];


end %PRICES.('nyiso').dam,

YY = Y(index);
XX = [ones(length(YY),1),X(index,:)];
ZZ = [ones(length(YY),1),Z(index,:)];
T = length(YY);

% First-stage
[B_GMM0,COVB0,B_GMM1,COVB1,B_GMM2,COVB2,Jtest,Jpval] = HAC_GMM(XX(:,3),ZZ,ZZ,1);
SE_GMM0 = sqrt(diag(COVB0));
SE_GMM1 = sqrt(diag(COVB1));
SE_GMM2 = sqrt(diag(COVB2));
table(B_GMM0,SE_GMM0,B_GMM1,SE_GMM1,B_GMM2,SE_GMM2);
B = B_GMM2;
SE = SE_GMM2;
SST = sum((XX(:,3)-mean(XX(:,3))).^2);
SSR = sum((XX(:,3) - ZZ*B).^2);
R2 = 1-SSR/SST;


RTM(i).FS(1).Info = 'RTM First-stage: overforecast';
RTM(i).FS(1).B = B;
RTM(i).FS(1).SE = SE;
RTM(i).FS(1).R2 = R2;
RTM(i).FS(1).OBS = sum(index);
RTM(i).FS(1).RMSE = sqrt(mean((XX(:,2)- ZZ*B).^2));

    
[B_GMM0,COVB0,B_GMM1,COVB1,B_GMM2,COVB2,Jtest,Jpval] = HAC_GMM(XX(:,4),ZZ,ZZ,1);
SE_GMM0 = sqrt(diag(COVB0));
SE_GMM1 = sqrt(diag(COVB1));
SE_GMM2 = sqrt(diag(COVB2));
table(B_GMM0,SE_GMM0,B_GMM1,SE_GMM1,B_GMM2,SE_GMM2);
B = B_GMM2;
SE = SE_GMM2;
SST = sum((XX(:,4)-mean(XX(:,4))).^2);
SSR = sum((XX(:,4) - ZZ*B).^2);
R2 = 1-SSR/SST;



RTM(i).FS(2).Info = 'RTM First-stage: underforecast';
RTM(i).FS(2).B = B;
RTM(i).FS(2).SE = SE;
RTM(i).FS(2).R2 = R2;
RTM(i).FS(2).OBS = sum(index);
RTM(i).FS(2).RMSE = sqrt(mean((XX(:,4)- ZZ*B).^2));

[B_GMM0,COVB0,B_GMM1,COVB1,B_GMM2,COVB2,Jtest,Jpval] = HAC_GMM(YY,XX,ZZ,1);
SE_GMM0 = sqrt(diag(COVB0));
SE_GMM1 = sqrt(diag(COVB1));
SE_GMM2 = sqrt(diag(COVB2));
table(B_GMM0(2:6),SE_GMM0(2:6),B_GMM1(2:6),SE_GMM1(2:6),B_GMM2(2:6),SE_GMM2(2:6))

B = B_GMM2;
SE = SE_GMM2;
SST = sum((Y(index)-mean(Y(index))).^2);
SSR = sum((Y(index) - XX*B).^2);
R2 = 1-SSR/SST;

RTM(i).Info = 'RTM';
RTM(i).B = B;
RTM(i).SE = SE;
RTM(i).R2 = R2;
RTM(i).OBS = sum(index);
RTM(i).RMSE = sqrt(mean((YY- XX*B).^2));

end


% Figure
C = linspecer(6);
figure(1)
YY_c = Y(index2);
XX_c = [ones(sum(index2),1),X(index2,:)];
semilogy(NYISO.Time(index2),smooth(YY_c,14*24),'-','color',C(2,:),'linewidth',2)
hold on
semilogy(NYISO.Time(index2),smooth(XX_c*B,14*24),':','color',C(1,:),'linewidth',2)
xline(datetime(2020,3,1),'--','color',C(4,:),'linewidth',1.1)
hold off
legend('Observed prices','Predicted prices','1st reported COVID-19 case in NY') %'Day-ahead prices','
set(gca,'FontSize',14)
set(legend,'Location','best')
ylabel('Real-time Prices ($/MWh, logscale)')
ylim([0 250])
yticks([10 50 100 150 200])
saveas(1,['RESULTS/FIGURES/plot_RTM_FIT.eps'],'epsc')
    


%% RTM Regression results
% Second-stage
clear TABLEVALS
ii=1;
for i = 1:2
    j=1;   
    for jj=2:6
        TABLEVALS{j,ii} = ['$',num2str(RTM(i).B(jj),'%0.2f'),'$'];
        TABLEVALS{j,ii+1} = ['$(',num2str(RTM(i).SE(jj),'%0.2f'),')\quad$'];
        j=j+1;
    end    
    TABLEVALS{j,ii} = ['$',num2str(RTM(i).OBS,'%0.0f'),' $'];
    TABLEVALS{j+1,ii} = ['$',num2str(RTM(i).R2,'%0.2f'),'$'];
    ii = ii+2;
end

for i=1:4
TABLEVALS{5,i} = TABLEVALS{3,i};
TABLEVALS{3,i} = ' ';
TABLEVALS{4,i} = ' ';
end

ii=5;
for i = 3:4
    j=1;   
    for jj=2:6
        TABLEVALS{j,ii} = ['$',num2str(RTM(i).B(jj),'%0.2f'),'$'];
        TABLEVALS{j,ii+1} = ['$(',num2str(RTM(i).SE(jj),'%0.2f'),')\quad$'];
        j=j+1;
    end    
    TABLEVALS{j,ii} = ['$',num2str(RTM(i).OBS,'%0.0f'),' $'];
    TABLEVALS{j+1,ii} = ['$',num2str(RTM(i).R2,'%0.2f'),'$'];
    ii = ii+2;
end

for i=5:8
TABLEVALS{5,i} = TABLEVALS{4,i};
TABLEVALS{4,i} = TABLEVALS{3,i};
TABLEVALS{3,i} = TABLEVALS{2,i};
TABLEVALS{2,i} = ' ';
end

TABLEVALS

ROWNAMES = {'$P^{DA}$','$D - \overline{D}$','$|\overline{D}-D|_{-}$','$|\overline{D}-D|_{+}$','$NG$'};
ROWNAMES{end+1} ='Obs.';
ROWNAMES{end+1} ='$R^2$';
COLNAMES = {' ',' ',' '};
TABLE = ['\begin{tabular*}{1\hsize}{@{\hskip\tabcolsep\extracolsep\fill}l*{9}{rrrrrrrr}}',...
    ' \hline  \hline ',...
    '& \multicolumn{2}{c}{GMM (1)}  & \multicolumn{2}{c}{IV-GMM (2)} & \multicolumn{2}{c}{GMM (3)} & \multicolumn{2}{c}{IV-GMM (4)}      \\',...
    ' \hline ',...
    ];
for j=1:7
    TABLE = [TABLE,...
        ROWNAMES{j},' & ',TABLEVALS{j,1},' & ',TABLEVALS{j,2},' & ',TABLEVALS{j,3},' & ',TABLEVALS{j,4},' & ',TABLEVALS{j,5},' & ',TABLEVALS{j,6},' & ',TABLEVALS{j,7},' & ',TABLEVALS{j,8},' \\ ']; 
    if j==5
         TABLE = [TABLE,' \hline ',]; 
    end
end

TABLE = [TABLE,...
    ' \hline \end{tabular*}'];

fileID = fopen(['RESULTS/TABLES/table_REGRTM.tex'],'w');
fprintf(fileID,'%s',TABLE);
fclose(fileID);

%First-stages
clear TABLEVALS
ii=1;
for i = 1:2 
    j=1;   
    for jj=2:5
        if jj==2 || jj==5
           TABLEVALS{j,ii} = ['$',num2str(RTM(4).FS(i).B(jj)*100,'%0.2f'),'$'];
        TABLEVALS{j,ii+1} = ['$(',num2str(RTM(4).FS(i).SE(jj)*100,'%0.2f'),')\quad \quad$']; 
        else
        TABLEVALS{j,ii} = ['$',num2str(RTM(4).FS(i).B(jj),'%0.2f'),'$'];
        TABLEVALS{j,ii+1} = ['$(',num2str(RTM(4).FS(i).SE(jj),'%0.2f'),')\quad \quad$'];
        end
        j=j+1;
    end    
    TABLEVALS{j,ii} = ['$',num2str(RTM(4).FS(i).OBS,'%0.0f'),' $'];
    TABLEVALS{j+1,ii} = ['$',num2str(RTM(4).FS(i).R2,'%0.2f'),'$'];
    ii = ii+2;
end

TABLEVALS

ROWNAMES = {'$P^{DA}\times 100$','$|\overline{D}^{NYC}-D^{NYC}|_{-}$', '$|\overline{D}^{NYC}-D^{NYC}|_{+}$', '$NG\times 100$'};
ROWNAMES{end+1} ='Obs.';
ROWNAMES{end+1} ='$R^2$';
COLNAMES = {' ',' ',' '};
TABLE = ['\begin{tabular*}{1\hsize}{@{\hskip\tabcolsep\extracolsep\fill}l*{5}{rrrr}}',...
    ' \hline  \hline ',...
    '& \multicolumn{2}{c}{$|\overline{D}-D|_{-}$}  & \multicolumn{2}{c}{$|\overline{D}-D|_{+}$}   \\',...
    ' \hline ',...
    ];
for j=1:6
    TABLE = [TABLE,...
        ROWNAMES{j},' & ',TABLEVALS{j,1},' & ',TABLEVALS{j,2},' & ',TABLEVALS{j,3},' & ',TABLEVALS{j,4},' \\ ']; 
    if j==4
         TABLE = [TABLE,' \hline ',]; 
    end
end

TABLE = [TABLE,...
    ' \hline \end{tabular*}'];

fileID = fopen(['RESULTS/TABLES/table_REGRTM_FS.tex'],'w');
fprintf(fileID,'%s',TABLE);
fclose(fileID);     


%% Descriptive stats for the regressions DAM/RTM

b0 = NYISO.Time >= datetime(2016,01,01) & NYISO.Time < datetime(2020,01,01);
b1 = NYISO.Time >= datetime(2020,01,01) & NYISO.Time < datetime(2021,03,01);

VARS = [PRICES.('nyiso').dam,PRICES.('nyiso').rtm,NYISO.fcst/1000,(X_netfload/1000),NYISO.ferr/1000,X_gasPrice,X_gasPrice_HH,NYISO.wind/1000+NYISO.otherRenewables/1000,X_nuclear,NYISO.NUKECAP,WEATHER.kalb.temperature];

TABLEDES = zeros(4,11);
TABLEDES(1,:) = nanmean(VARS(b0,:));
TABLEDES(2,:) = nanstd(VARS(b0,:));
TABLEDES(3,:) = quantile(VARS(b0,:),0.95);
TABLEDES(4,:) = quantile(VARS(b0,:),0.05);
TABLEDES
TABLEDES2 = zeros(4,11);
TABLEDES2(1,:) = nanmean(VARS(b1,:));
TABLEDES2(2,:) = nanstd(VARS(b1,:));
TABLEDES2(3,:) = quantile(VARS(b1,:),0.95);
TABLEDES2(4,:) = quantile(VARS(b1,:),0.05);
TABLEDES2

TABLEDES = [TABLEDES;TABLEDES2];

clear TABLEVALS TABLEVALS2
TARGET= TABLEDES';
for i = 1:size(TARGET,1)
    for j=1:size(TARGET,2)
TABLEVALS{i,j} = ['$',num2str(TARGET(i,j),'%0.2f'),'$'];
    end
end

ROWNAMES = {'$P^{DA}$ (\$)','$P^{RT}$ (\$)','$\overline{D}$ (GW)','$\overline{D}-N-R$ (GW)','$FE$ (GW)','$NG$ T6NY (\$)','$NG$ HH (\$)','$R$ (GW)','$N$ (GW)','Nuclear Cap. (\%)','$Temp$ ($^{\circ}F$)'};
COLNAMES = {' ',' ',' '};
TABLE = ['\begin{tabular*}{1\hsize}{@{\hskip\tabcolsep\extracolsep\fill}l*{9}{c}}',...
    ' \hline  \hline ',... 
    '& \multicolumn{4}{c}{2016-2019} & \multicolumn{4}{c}{2020-2021}  \\',...
    '& Mean & Std &  95th p. & 5th p. & Mean & Std &  95th p. & 5th p.   \\',...
    ' \hline ',...
    ];
    for i=1:size(TABLEVALS,1)
        TABLE = [TABLE,...
        ROWNAMES{i},' & ',TABLEVALS{i,1},' & ',TABLEVALS{i,2},' & ',TABLEVALS{i,3},' & ',TABLEVALS{i,4},' & ',TABLEVALS{i,5},' & ',TABLEVALS{i,6},' & ',TABLEVALS{i,7},' & ',TABLEVALS{i,8},...
        ' \\ '];
    end
    
TABLE = [TABLE,...
    ' \hline \end{tabular*}'];

    fileID = fopen(['RESULTS/TABLES/table_DESCRREG.tex'],'w');
    fprintf(fileID,'%s',TABLE);
    fclose(fileID);    
    
%% Counterfactual prices   
% 1. = No lockdown
% 1. = No NG collapse
% 3. = No nuclear phase-out
% 4. = No abnormal Ferrs
% 5. = 1. + 2. + 4.

% Scenario 1: No Lockdown
index = NYISO.Time >= datetime(2020,01,01) & NYISO.Time < datetime(2021,03,01);
index2 = NYISO.Time >= datetime(2020,03,01) & NYISO.Time < datetime(2021,03,01);
index3 = NYISO.Time >= datetime(2020,01,01) & NYISO.Time < datetime(2020,03,01);

PRICES.nyiso.dam_cft_1 = PRICES.nyiso.dam;
PRICES.nyiso.dam_cft_1(index2) = PRICES.nyiso.dam(index2) + DAM(3).B(2)*(NYISO.cfct(index2) - NYISO.fcst(index2))/1000;

plot(NYISO.Time(index), smooth(PRICES.nyiso.dam_cft_1(index),72))
hold on
plot(NYISO.Time(index), smooth(PRICES.nyiso.dam(index),72))
hold off
xlim([datetime(2020,1,1) datetime(2021,3,1)])
ylim([-10 150])

PRICES.nyiso.rtm_cft_1 = PRICES.nyiso.rtm;
PRICES.nyiso.rtm_cft_1(index2) = PRICES.nyiso.rtm(index2) +(PRICES.nyiso.dam_cft_1(index2)-PRICES.nyiso.dam(index2));

plot(NYISO.Time(index), smooth(PRICES.nyiso.rtm_cft_1(index),72))
hold on
plot(NYISO.Time(index), smooth(PRICES.nyiso.rtm(index),72))
hold off
xlim([datetime(2020,1,1) datetime(2021,3,1)])
ylim([-10 150])

% Scenario 2: No Fuel Price Drop
PRICES.nyiso.dam_cft_2 = PRICES.nyiso.dam;
PRICES.nyiso.dam_cft_2(index2) = PRICES.nyiso.dam(index2) + DAM(3).B(3)*(-NG(1).B(1));

plot(NYISO.Time(index), smooth(PRICES.nyiso.dam_cft_2(index),72))
hold on
plot(NYISO.Time(index), smooth(PRICES.nyiso.dam(index),72))
hold off
xlim([datetime(2020,1,1) datetime(2021,3,1)])
ylim([-10 150])

PRICES.nyiso.rtm_cft_2 = PRICES.nyiso.rtm;
PRICES.nyiso.rtm_cft_2(index2) = PRICES.nyiso.rtm(index2) +(PRICES.nyiso.dam_cft_2(index2)-PRICES.nyiso.dam(index2));

plot(NYISO.Time(index), smooth(PRICES.nyiso.rtm_cft_2(index),72))
hold on
plot(NYISO.Time(index), smooth(PRICES.nyiso.rtm(index),72))
hold off
xlim([datetime(2020,1,1) datetime(2021,3,1)])
ylim([-10 150])


% Scenario 3: No Nuclear Retirement
PRICES.nyiso.dam_cft_3 = PRICES.nyiso.dam;
PRICES.nyiso.dam_cft_3(index2) = PRICES.nyiso.dam(index2) + (DAM(3).B(4)-DAM(3).B(2))*(Nuke_c(index2)/1000 - NYISO.nuclear(index2)/1000);

plot(NYISO.Time(index), smooth(PRICES.nyiso.dam_cft_3(index),72))
hold on
plot(NYISO.Time(index), smooth(PRICES.nyiso.dam(index),72))
hold off
xlim([datetime(2020,1,1) datetime(2021,3,1)])
ylim([-10 150])

PRICES.nyiso.rtm_cft_3 = PRICES.nyiso.rtm;
PRICES.nyiso.rtm_cft_3(index2) = PRICES.nyiso.rtm(index2) +(PRICES.nyiso.dam_cft_3(index2)-PRICES.nyiso.dam(index2));

plot(NYISO.Time(index), smooth(PRICES.nyiso.rtm_cft_3(index),72))
hold on
plot(NYISO.Time(index), smooth(PRICES.nyiso.rtm(index),72))
hold off
xlim([datetime(2020,1,1) datetime(2021,3,1)])
ylim([-10 150])

% Scenario 4: No Abnormal F. errors
PRICES.nyiso.dam_cft_4 = PRICES.nyiso.dam;
PRICES.nyiso.rtm_cft_4 = PRICES.nyiso.rtm;

PRICES.nyiso.rtm_cft_4(index5) = PRICES.nyiso.rtm(index5) ...
    + RTM(4).B(3)*((FERR(5).cft<=0).*abs(FERR(5).cft)/1000 - (NYISO.ferr(index5)<=0).*abs(NYISO.ferr(index5))/1000) ...
    + RTM(4).B(4)*((FERR(5).cft>0).*abs(FERR(5).cft)/1000 - (NYISO.ferr(index5)>0).*abs(NYISO.ferr(index5))/1000);

plot(NYISO.Time(index), smooth(PRICES.nyiso.rtm_cft_4(index),72))
hold on
plot(NYISO.Time(index), smooth(PRICES.nyiso.rtm(index),72))
hold off
xlim([datetime(2020,1,1) datetime(2021,3,1)])
ylim([-10 150])

% Scenario 5: No Lockdown + No Fuel Price Drop + No Nuclear RR + No Abnormal F. errors
PRICES.nyiso.dam_cft_5 = PRICES.nyiso.dam;
PRICES.nyiso.dam_cft_5(index2) = PRICES.nyiso.dam(index2) + DAM(3).B(2)*(NYISO.cfct(index2) - NYISO.fcst(index2))/1000 + DAM(3).B(3)*(-NG(1).B(1)) + (DAM(3).B(4)-DAM(3).B(2))*(Nuke_c(index2)/1000 - NYISO.nuclear(index2)/1000);

plot(NYISO.Time(index), smooth(PRICES.nyiso.dam_cft_5(index),72))
hold on
plot(NYISO.Time(index), smooth(PRICES.nyiso.dam(index),72))
hold off
xlim([datetime(2020,1,1) datetime(2021,3,1)])
ylim([-10 150])

PRICES.nyiso.rtm_cft_5 = PRICES.nyiso.rtm;

PRICES.nyiso.rtm_cft_5(index5) = PRICES.nyiso.rtm(index5) + (PRICES.nyiso.dam_cft_5(index5)-PRICES.nyiso.dam(index5)) ...
    + RTM(4).B(3)*((FERR(5).cft<=0).*abs(FERR(5).cft)/1000 - (NYISO.ferr(index5)<=0).*abs(NYISO.ferr(index5))/1000) ...
    + RTM(4).B(4)*((FERR(5).cft>0).*abs(FERR(5).cft)/1000 - (NYISO.ferr(index5)>0).*abs(NYISO.ferr(index5))/1000);

plot(NYISO.Time(index), smooth(PRICES.nyiso.rtm_cft_5(index),72))
hold on
plot(NYISO.Time(index), smooth(PRICES.nyiso.rtm(index),72))
hold off
xlim([datetime(2020,1,1) datetime(2021,3,1)])
ylim([-10 150])

% Scenario 6: No Lockdown + No Fuel Price Drop + No Abnormal F. errors
PRICES.nyiso.dam_cft_6 = PRICES.nyiso.dam;
PRICES.nyiso.dam_cft_6(index2) = PRICES.nyiso.dam(index2) + DAM(3).B(2)*(NYISO.cfct(index2) - NYISO.fcst(index2))/1000 + DAM(3).B(3)*(-NG(1).B(1));


PRICES.nyiso.rtm_cft_6 = PRICES.nyiso.rtm;

PRICES.nyiso.rtm_cft_6(index5) = PRICES.nyiso.rtm(index5) + (PRICES.nyiso.dam_cft_6(index5)-PRICES.nyiso.dam(index5)) ...
    + RTM(4).B(3)*((FERR(5).cft<=0).*abs(FERR(5).cft)/1000 - (NYISO.ferr(index5)<=0).*abs(NYISO.ferr(index5))/1000) ...
    + RTM(4).B(4)*((FERR(5).cft>0).*abs(FERR(5).cft)/1000 - (NYISO.ferr(index5)>0).*abs(NYISO.ferr(index5))/1000);



C = linspecer(6);
spar = 10;

figure(1)
plot(NYISO.Time(index), smooth(PRICES.nyiso.dam(index),24*spar),'color',C(2,:),'LineWidth',2)
hold on
%plot(NYISO.Time(index), smooth(PRICES.nyiso.dam_cft_5(index),24*spar),'color',C(1,:),'LineWidth',1)
plot(NYISO.Time(index), smooth(PRICES.nyiso.dam_cft_6(index),24*spar),'color',C(1,:),'LineWidth',2)
plot([datetime(2020,3,1) datetime(2020,3,1)],[0 6000],'--k','color',C(4,:),'linewidth',1)
plot(NYISO.Time(index), smooth(PRICES.nyiso.dam(index),24*spar),'color',C(2,:),'LineWidth',2)
hold off
xlim([datetime(2020,1,1) datetime(2021,3,1)])
ylim([5 95])
ylabel('Day-ahead price ($/MWh)')
legend('Actual','Counterfactual: Scenarios 1+2+4','1st reported COVID case in NY','location','best')
set(gca,'Fontsize',14)
saveas(1,['RESULTS/FIGURES/plot_DAprice_cft.eps'],'epsc')

figure(2)
plot(NYISO.Time(index), smooth(PRICES.nyiso.rtm(index),24*spar),'color',C(2,:),'LineWidth',2)
hold on
%plot(NYISO.Time(index), smooth(PRICES.nyiso.rtm_cft_5(index),24*spar),'color',C(1,:),'LineWidth',1)
plot(NYISO.Time(index), smooth(PRICES.nyiso.rtm_cft_6(index),24*spar),'color',C(1,:),'LineWidth',2)
plot([datetime(2020,3,1) datetime(2020,3,1)],[0 6000],'--k','color',C(4,:),'linewidth',1)
plot(NYISO.Time(index), smooth(PRICES.nyiso.rtm(index),24*spar),'color',C(2,:),'LineWidth',2)
hold off
xlim([datetime(2020,1,1) datetime(2021,3,1)])
ylim([5 95])
ylabel('Real-time price ($/MWh)')
legend('Actual','Counterfactual: Scenarios 1+2+4','1st reported COVID case in NY','location','best')
set(gca,'Fontsize',14)
saveas(2,['RESULTS/FIGURES/plot_RTprice_cft.eps'],'epsc')

%% Breaking down day-ahead impacts

NYISO.LOCKDOWN = NYISO.cfct*0;
NYISO.GAS = NYISO.cfct*0;
NYISO.NUKE = NYISO.cfct*0;

NYISO.LOCKDOWN(index2) = -DAM(3).B(2)*(NYISO.cfct(index2) - NYISO.fcst(index2))/1000;
NYISO.GAS(index2) = ones(sum(index2),1)*DAM(3).B(3)*(NG(1).B(1));
NYISO.NUKE(index2) = -(DAM(3).B(4)-DAM(3).B(2))*(Nuke_c(index2)/1000 - NYISO.nuclear(index2)/1000);

plot(NYISO.Time(index),smooth(NYISO.LOCKDOWN(index),24*7))
hold on
plot(NYISO.Time(index),smooth(NYISO.GAS(index),24*7))
plot(NYISO.Time(index),smooth(NYISO.NUKE(index),24*7))
hold off

spar = 15;
Data = [smooth(NYISO.LOCKDOWN,24*spar)'; ...
    smooth(NYISO.GAS,24*spar)'; ...
    smooth(NYISO.NUKE,24*spar)'; ...
   ]';

pos = Data;
pos(pos<0)=nan;
neg = -Data;
neg(neg<0)=nan;

C =[168 197 57;...
254 221 63;...
159 85 156;...
225 142 188
21 158 206;...
246 146 36;...
236 81 82;...
58 175 153;...
171 171 171;...
104 106 176;...
182 129 74
]/255;

f = figure(1)
a1 = area(NYISO.Time,pos)
hold on
plot(NYISO.Time(index),smooth(NYISO.LOCKDOWN(index)+NYISO.GAS(index)+NYISO.NUKE(index),24*spar),':r','LineWidth',3)
%plot(NYISO.Time(index),smooth(NYISO.LOCKDOWN(index)+NYISO.GAS(index),24*spar),'--k','LineWidth',2)
a2 = area(NYISO.Time,-neg)
plot(NYISO.Time(index),smooth(NYISO.LOCKDOWN(index)+NYISO.GAS(index)+NYISO.NUKE(index),24*spar),':r','LineWidth',3)
%plot(NYISO.Time(index),smooth(NYISO.LOCKDOWN(index)+NYISO.GAS(index),24*spar),'--k','LineWidth',2)
xline(datetime(2020,03,01))
hold off
xlim([datetime(2020,03,1) datetime(2021,02,28)])

for i=1:3
a1(i).FaceColor = C(i,:);
a2(i).FaceColor = C(i,:);
a1(i).FaceAlpha = 1-0.1*i;
a2(i).FaceAlpha = 1-0.1*i;
end
ylim([-12 5])
ylabel('Day-ahead price impacts ($/MWh)')
legend('Lockdown Measures','Natural Gas Price Drop','Nuclear Reactor Retirement','Combined','location','best')
set(gca,'Fontsize',14)

saveas(1,['RESULTS/FIGURES/plot_DApriceimpacts.eps'],'epsc')

%% Breaking down real-time impacts

NYISO.ERR = NYISO.cfct*0;

NYISO.ERR(index5) = - RTM(4).B(3)*((FERR(5).cft<=0).*abs(FERR(5).cft)/1000 - (NYISO.ferr(index5)<=0).*abs(NYISO.ferr(index5))/1000) ...
    - RTM(4).B(4)*((FERR(5).cft>0).*abs(FERR(5).cft)/1000 - (NYISO.ferr(index5)>0).*abs(NYISO.ferr(index5))/1000);


spar = 15;
Data = [smooth(NYISO.LOCKDOWN,24*spar)'; ...
    smooth(NYISO.GAS,24*spar)'; ...
    smooth(NYISO.NUKE,24*spar)'; ...
    smooth(NYISO.ERR,24*spar)'; ...
   ]';

pos = Data;
pos(pos<0)=nan;
neg = -Data;
neg(neg<0)=nan;

f = figure(1)
a1 = area(NYISO.Time,pos)
hold on
plot(NYISO.Time(index),smooth(NYISO.LOCKDOWN(index)+NYISO.GAS(index)+NYISO.NUKE(index)+NYISO.ERR(index),24*spar),':r','LineWidth',3)
%plot(NYISO.Time(index),smooth(NYISO.LOCKDOWN(index)+NYISO.GAS(index)+NYISO.ERR(index),24*spar),'--k','LineWidth',2)
a2 = area(NYISO.Time,-neg)
plot(NYISO.Time(index),smooth(NYISO.LOCKDOWN(index)+NYISO.GAS(index)+NYISO.NUKE(index)+NYISO.ERR(index),24*spar),':r','LineWidth',3)
%plot(NYISO.Time(index),smooth(NYISO.LOCKDOWN(index)+NYISO.GAS(index)+NYISO.ERR(index),24*spar),'--k','LineWidth',2)
xline(datetime(2020,03,01))
hold off
xlim([datetime(2020,03,1) datetime(2021,02,28)])
ylim([-12 5])
for i=1:4
a1(i).FaceColor = C(i,:);
a2(i).FaceColor = C(i,:);
a1(i).FaceAlpha = 1-0.1*i;
a2(i).FaceAlpha = 1-0.1*i;
end
ylabel('Real-time price impacts ($/MWh)')
legend('Lockdown Measures','Natural Gas Price Drop','Nuclear Reactor Retirement','Abnormal Forecast Errors','Combined','location','best')

set(gca,'Fontsize',14)
%applyhatch_plusC(f, '\-x.', 'rgbk',[],600,3);
saveas(1,['RESULTS/FIGURES/plot_RTpriceimpacts.eps'],'epsc')

%% Breaking down day-ahead market impacts

% DAM value loss = P_cft*D_cft - P_obs*D_obs
NYISO.LOCKDOWN_M = NYISO.LOCKDOWN.*NYISO.fcst + PRICES.nyiso.dam_cft_5.*(NYISO.fcst-NYISO.cfct); %NYISO.fcst is biased! use rlze instead
NYISO.LOCKDOWN_M2 = NYISO.LOCKDOWN.*NYISO.fcst + PRICES.nyiso.dam_cft_6.*(NYISO.fcst-NYISO.cfct);
NYISO.GAS_M = NYISO.GAS.*NYISO.fcst;
NYISO.NUKE_M = NYISO.NUKE.*NYISO.fcst;

index4 = NYISO.Time >= datetime(2016,01,01) & NYISO.Time < datetime(2020,03,01);

NYISO.LOCKDOWN_M(index4) = 0;
NYISO.LOCKDOWN_M2(index4) = 0;
NYISO.GAS_M(index4) = 0;
NYISO.NUKE_M(index4) = 0;

NYISO_w = retime(NYISO,'weekly','mean');
NYISO_w = retime(NYISO_w,'hourly','mean');
NYISO_w = fillmissing(NYISO_w,'previous');

Data = [smooth(cumsum(NYISO_w.LOCKDOWN_M),24*3)'; ...
    smooth(cumsum(NYISO_w.GAS_M),24*3)'; ...
    smooth(cumsum(NYISO_w.NUKE_M),24*3)'; ...
   ]';

pos = Data;
pos(pos<0)=nan;
neg = -Data;
neg(neg<0)=nan;


f = figure(1)
a1 = area(NYISO_w.Time,pos/1e6)
hold on
plot(NYISO_w.Time(index),smooth(cumsum(NYISO_w.LOCKDOWN_M(index)+NYISO_w.GAS_M(index)+NYISO_w.NUKE_M(index))/1e6,24*3),':r','LineWidth',3)
%plot(NYISO_w.Time(index),smooth(cumsum(NYISO_w.LOCKDOWN_M2(index)+NYISO_w.GAS_M(index))/1e6,24*3),'--k','LineWidth',2)
a2 = area(NYISO_w.Time,-neg/1e6)
plot(NYISO_w.Time(index),smooth(cumsum(NYISO_w.LOCKDOWN_M(index)+NYISO_w.GAS_M(index)+NYISO_w.NUKE_M(index))/1e6,24*3),':r','LineWidth',3)
%plot(NYISO_w.Time(index),smooth(cumsum(NYISO_w.LOCKDOWN_M2(index)+NYISO_w.GAS_M(index))/1e6,24*3),'--k','LineWidth',2)
xline(datetime(2020,03,01))
hold off
xlim([datetime(2020,03,1) datetime(2021,02,28)])

for i=1:3
a1(i).FaceColor = C(i,:);
a2(i).FaceColor = C(i,:);
a1(i).FaceAlpha = 1-0.1*i;
a2(i).FaceAlpha = 1-0.1*i;
end
ylim([-600 300])
ylabel('Cumulative day-ahead market impacts (million $)')
legend('Lockdown Measures','Natural Gas Price Drop','Nuclear Reactor Retirement','Combined','location','best')
set(gca,'Fontsize',14)

saveas(1,['RESULTS/FIGURES/plot_DAmarketimpacts.eps'],'epsc')

%% Breaking down balancing costs

% DAM value loss = P_cft*D_cft - P_obs*D_obs
NYISO.LOCKDOWN_R = 0*NYISO.LOCKDOWN;
NYISO.LOCKDOWN_R(index5) = NYISO.LOCKDOWN(index5).*abs(FERR(5).cft);
NYISO.GAS_R = 0*NYISO.LOCKDOWN;
NYISO.GAS_R(index5) = NYISO.GAS(index5).*abs(FERR(5).cft);
NYISO.NUKE_R = 0*NYISO.LOCKDOWN;
NYISO.NUKE_R(index5) = NYISO.NUKE(index5).*abs(FERR(5).cft);
NYISO.ERR_R = 0*NYISO.LOCKDOWN;
NYISO.ERR_R2 = 0*NYISO.LOCKDOWN;

NYISO.ERR_R(index5) = PRICES.nyiso.rtm(index5).*abs(NYISO.ferr(index5)) - PRICES.nyiso.rtm_cft_5(index5).*abs(FERR(5).cft);
NYISO.ERR_R(index5) = fillmissing(NYISO.ERR_R(index5),'linear');
NYISO.ERR_R2(index5) = PRICES.nyiso.rtm(index5).*abs(NYISO.ferr(index5)) - PRICES.nyiso.rtm_cft_6(index5).*abs(FERR(5).cft);
NYISO.ERR_R2(index5) = fillmissing(NYISO.ERR_R2(index5),'linear');
plot(NYISO.Time(index2),cumsum(NYISO.ERR_R(index2)))

NYISO.ERR_R = NYISO.ERR_R - NYISO.LOCKDOWN_R - NYISO.GAS_R - NYISO.NUKE_R;
NYISO.ERR_R2 = NYISO.ERR_R2 - NYISO.LOCKDOWN_R - NYISO.GAS_R;

NYISO.balacingcosts_cft = PRICES.nyiso.rtm.*abs(NYISO.ferr);
NYISO.balacingcosts_cft(index5) = PRICES.nyiso.rtm_cft_5(index5).*abs(FERR(5).cft);
NYISO.balacingcosts_cft = fillmissing(NYISO.balacingcosts_cft,'linear');
NYISO.balacingcosts_cft2 = PRICES.nyiso.rtm.*abs(NYISO.ferr);
NYISO.balacingcosts_cft2(index5) = PRICES.nyiso.rtm_cft_6(index5).*abs(FERR(5).cft);
NYISO.balacingcosts_cft2 = fillmissing(NYISO.balacingcosts_cft2,'linear');

NYISO_w = retime(NYISO,'weekly','mean');
NYISO_w = retime(NYISO_w,'hourly','mean');
NYISO_w = fillmissing(NYISO_w,'previous');

Data = [smooth(cumsum(NYISO_w.LOCKDOWN_R),24*3)'; ...
    smooth(cumsum(NYISO_w.GAS_R),24*3)'; ...
    smooth(cumsum(NYISO_w.NUKE_R),24*3)'; ...
    smooth(cumsum(NYISO_w.ERR_R),24*3)'; ...
   ]';

pos = Data;
pos(pos<0)=nan;
neg = -Data;
neg(neg<0)=nan;


f = figure(1)
a1 = area(NYISO_w.Time,pos/1e6)
hold on
plot(NYISO_w.Time(index),smooth(cumsum(NYISO_w.LOCKDOWN_R(index)+NYISO_w.GAS_R(index)+NYISO_w.NUKE_R(index)+NYISO_w.ERR_R(index))/1e6,24*3),':r','LineWidth',3)
%plot(NYISO_w.Time(index),smooth(cumsum(NYISO_w.LOCKDOWN_R(index)+NYISO_w.GAS_R(index)+NYISO_w.ERR_R2(index))/1e6,24*3),'--k','LineWidth',2)
a2 = area(NYISO_w.Time,-neg/1e6)
plot(NYISO_w.Time(index),smooth(cumsum(NYISO_w.LOCKDOWN_R(index)+NYISO_w.GAS_R(index)+NYISO_w.NUKE_R(index)+NYISO_w.ERR_R(index))/1e6,24*3),':r','LineWidth',3)
%plot(NYISO_w.Time(index),smooth(cumsum(NYISO_w.LOCKDOWN_R(index)+NYISO_w.GAS_R(index)+NYISO_w.ERR_R2(index))/1e6,24*3),'--k','LineWidth',2)
xline(datetime(2020,03,01))
hold off
xlim([datetime(2020,03,1) datetime(2021,02,27)])

for i=1:4
a1(i).FaceColor = C(i,:);
a2(i).FaceColor = C(i,:);
a1(i).FaceAlpha = 1-0.1*i;
a2(i).FaceAlpha = 1-0.1*i;
end
ylim([-10 30])
ylabel('Cumulative day-ahead market impacts (million $)')
legend('Lockdown Measures','Natural Gas Price Drop','Nuclear Reactor Retirement','Abnormal Forecast Errors','Combined','location','best')
set(gca,'Fontsize',14)

saveas(1,['RESULTS/FIGURES/plot_RTmarketimpacts.eps'],'epsc')

%% Breaking down total impacts

Data = [smooth(cumsum(NYISO_w.LOCKDOWN_M+NYISO_w.LOCKDOWN_R),24*3)'; ...
    smooth(cumsum(NYISO_w.GAS_M+NYISO_w.GAS_R),24*3)'; ...
    smooth(cumsum(NYISO_w.NUKE_M+NYISO_w.NUKE_R),24*3)'; ...
    smooth(cumsum(NYISO_w.ERR_R),24*3)'; ...
   ]';


pos = Data;
pos(pos<0)=nan;
neg = -Data;
neg(neg<0)=nan;


f = figure(1)
a1 = area(NYISO_w.Time,pos/1e6)
hold on
a2 = area(NYISO_w.Time,-neg/1e6)
xline(datetime(2020,03,01))
hold off
xlim([datetime(2020,03,1) datetime(2021,02,27)])

%, 'FaceAlpha',0.1

for i=1:4
a1(i).FaceColor = C(i,:);
a2(i).FaceColor = C(i,:);
a1(i).FaceAlpha = 1-0.1*i;
a2(i).FaceAlpha = 1-0.1*i;
end
ylim([-610 330])
ylabel('Cumulative day-ahead market impacts (million $)')
legend('Lockdown Measures','Natural Gas Price Drop','Nuclear Reactor Retirement','Abnormal Forecast Errors','location','best')
set(gca,'Fontsize',14)

saveas(1,['RESULTS/FIGURES/plot_Tmarketimpacts.eps'],'epsc')

%% Some stats to be discussed
%Maybe just look at first 4 months: M,A,M,J not 6 months.

%Inefficiency caused by abnormal forecast errors?
NYISO.ferr_abs = abs(NYISO.ferr);
NYISO.ferr_abs_cft = NYISO.ferr_abs;
NYISO.ferr_abs_cft(index5) = abs(FERR(5).cft);

%Relative effect
NYISO_m = retime(NYISO,'monthly','mean');
idx = find(NYISO_m.Time>=datetime(2020,03,01) & NYISO_m.Time<datetime(2020,08,01));
sum(NYISO_m.ERR_R(idx))./sum(NYISO_m.balacingcosts_cft(idx)) % 36%
sum(NYISO_m.ERR_R2(idx))./sum(NYISO_m.balacingcosts_cft2(idx)) % 34%
idx = find(NYISO_m.Time>=datetime(2020,03,01) & NYISO_m.Time<datetime(2021,03,01));
sum(NYISO_m.ERR_R(idx))./sum(NYISO_m.balacingcosts_cft(idx)) % 15%
sum(NYISO_m.ERR_R2(idx))./sum(NYISO_m.balacingcosts_cft2(idx)) % 14%

%Total costs
NYISO_m = retime(NYISO,'monthly','sum');
idx = find(NYISO_m.Time>=datetime(2020,03,01) & NYISO_m.Time<datetime(2020,08,01));
sum(NYISO_m.ERR_R(idx))  % 1.4788e+07
sum(NYISO_m.balacingcosts_cft(idx)) % 4.0923e+07
sum(NYISO_m.ERR_R2(idx))% 1.2371e+07
sum(NYISO_m.balacingcosts_cft2(idx))   %  4.3340e+07

%Abnormal errors?
sum(NYISO_m.ferr_abs(idx)) %2.4564 million MWh (+65% for error volume!)
sum(NYISO_m.ferr_abs_cft(idx)) %1.4906e+06 million MWh 
%extra 1 TWh of errors to be balanced at a real-time cost between 12 and 15$ per
%MWhh.

%Demand reductions first year
%NYC
idx = find(LOAD.nyc.Time>=datetime(2020,03,01) & LOAD.nyc.Time<datetime(2021,03,01));
(sum(LOAD.nyc.rlze(idx))-sum(LOAD.nyc.cfct(idx)))./sum(LOAD.nyc.cfct(idx)) % in perc
(sum(LOAD.nyc.rlze(idx))-sum(LOAD.nyc.cfct(idx)))/1e6 %TWh
%NYISO
(sum(LOAD.nyiso.rlze(idx))-sum(LOAD.nyiso.cfct(idx)))./sum(LOAD.nyiso.cfct(idx)) % in perc
(sum(LOAD.nyiso.rlze(idx))-sum(LOAD.nyiso.cfct(idx)))/1e6 %TWh
%Demand reductions first months
%NYC
idx = find(LOAD.nyc.Time>=datetime(2020,03,01) & LOAD.nyc.Time<datetime(2020,08,01));
(sum(LOAD.nyc.rlze(idx))-sum(LOAD.nyc.cfct(idx)))./sum(LOAD.nyc.cfct(idx)) % in perc
(sum(LOAD.nyc.rlze(idx))-sum(LOAD.nyc.cfct(idx)))/1e6 %TWh
%NYISO
(sum(LOAD.nyiso.rlze(idx))-sum(LOAD.nyiso.cfct(idx)))./sum(LOAD.nyiso.cfct(idx)) % in perc
(sum(LOAD.nyiso.rlze(idx))-sum(LOAD.nyiso.cfct(idx)))/1e6 %TWh

%Week before
%NYC
idx = find(LOAD.nyc.Time>=datetime(2020,03,09) & LOAD.nyc.Time<datetime(2020,03,15));
(sum(LOAD.nyc.rlze(idx))-sum(LOAD.nyc.cfct(idx)))./sum(LOAD.nyc.cfct(idx)) % in perc
(sum(LOAD.nyc.rlze(idx))-sum(LOAD.nyc.cfct(idx)))/1e3 %TWh
%NYISO
(sum(LOAD.nyiso.rlze(idx))-sum(LOAD.nyiso.cfct(idx)))./sum(LOAD.nyiso.cfct(idx)) % in perc
(sum(LOAD.nyiso.rlze(idx))-sum(LOAD.nyiso.cfct(idx)))/1e3 %TWh

%Schools
%NYC
idx = find(LOAD.nyc.Time>=datetime(2020,03,16) & LOAD.nyc.Time<datetime(2020,03,22));
(sum(LOAD.nyc.rlze(idx))-sum(LOAD.nyc.cfct(idx)))./sum(LOAD.nyc.cfct(idx)) % in perc
(sum(LOAD.nyc.rlze(idx))-sum(LOAD.nyc.cfct(idx)))/1e3 %TWh
%NYISO
(sum(LOAD.nyiso.rlze(idx))-sum(LOAD.nyiso.cfct(idx)))./sum(LOAD.nyiso.cfct(idx)) % in perc
(sum(LOAD.nyiso.rlze(idx))-sum(LOAD.nyiso.cfct(idx)))/1e3 %TWh

%Lockdown
%NYC
idx = find(LOAD.nyc.Time>=datetime(2020,03,23) & LOAD.nyc.Time<datetime(2020,03,29));
(sum(LOAD.nyc.rlze(idx))-sum(LOAD.nyc.cfct(idx)))./sum(LOAD.nyc.cfct(idx)) % in perc
(sum(LOAD.nyc.rlze(idx))-sum(LOAD.nyc.cfct(idx)))/1e3 %TWh
%NYISO
(sum(LOAD.nyiso.rlze(idx))-sum(LOAD.nyiso.cfct(idx)))./sum(LOAD.nyiso.cfct(idx)) % in perc
(sum(LOAD.nyiso.rlze(idx))-sum(LOAD.nyiso.cfct(idx)))/1e3 %TWh

%Average DA and RT price impacts?
TABLES = nan(4,2,2);
idx = NYISO.Time >= datetime(2020,03,01) & NYISO.Time < datetime(2021,03,01); 
% Note that (PRICES.nyiso.dam_cft_6(idx) - PRICES.nyiso.dam(idx)) is the
% price effect of lockdown+gas, it does not include the mitigating effect of the nuke retirement.
effect_5 = (PRICES.nyiso.dam_cft_5(idx) - PRICES.nyiso.dam(idx))./mean(NYISO.cfct(idx)).*(NYISO.cfct(idx));
effect_6 = (PRICES.nyiso.dam_cft_6(idx) - PRICES.nyiso.dam(idx))./mean(NYISO.cfct(idx)).*(NYISO.cfct(idx));
TABLES(1,1,1) = nanmean(effect_5);
TABLES(2,1,1) = nanmean(effect_6);
effect_5 = (PRICES.nyiso.dam_cft_5(idx))./mean(NYISO.cfct(idx)).*(NYISO.cfct(idx));
effect_6 = (PRICES.nyiso.dam_cft_6(idx))./mean(NYISO.cfct(idx)).*(NYISO.cfct(idx));
TABLES(1,2,1) = nanmean(effect_5);
TABLES(2,2,1) = nanmean(effect_6);
idx = NYISO.Time >= datetime(2020,03,01) & NYISO.Time < datetime(2020,08,01);
effect_5 = (PRICES.nyiso.dam_cft_5(idx) - PRICES.nyiso.dam(idx))./mean(NYISO.cfct(idx)).*(NYISO.cfct(idx));
effect_6 = (PRICES.nyiso.dam_cft_6(idx) - PRICES.nyiso.dam(idx))./mean(NYISO.cfct(idx)).*(NYISO.cfct(idx));
TABLES(3,1,1) = nanmean(effect_5);
TABLES(4,1,1) = nanmean(effect_6);
effect_5 = (PRICES.nyiso.dam_cft_5(idx))./mean(NYISO.cfct(idx)).*(NYISO.cfct(idx));
effect_6 = (PRICES.nyiso.dam_cft_6(idx))./mean(NYISO.cfct(idx)).*(NYISO.cfct(idx));
TABLES(3,2,1) = nanmean(effect_5);
TABLES(4,2,1) = nanmean(effect_6);

table({'DAM, No Nuke RR, 12 Months';'DAM, Nuke RR, 12 Months';'DAM, No Nuke RR, 6 Months';'DAM, Nuke RR, 6 Months'},-TABLES(:,1,1),-TABLES(:,1,1)./TABLES(:,2,1))


idx = NYISO.Time >= datetime(2020,03,01) & NYISO.Time < datetime(2021,03,01); 
effect_5 = (PRICES.nyiso.rtm_cft_5(idx) - PRICES.nyiso.rtm(idx))./mean(NYISO.cfct(idx)).*(NYISO.cfct(idx));
effect_6 = (PRICES.nyiso.rtm_cft_6(idx) - PRICES.nyiso.rtm(idx))./mean(NYISO.cfct(idx)).*(NYISO.cfct(idx));
TABLES(1,1,2) = nanmean(effect_5);
TABLES(2,1,2) = nanmean(effect_6);
effect_5 = (PRICES.nyiso.rtm_cft_5(idx))./mean(NYISO.cfct(idx)).*(NYISO.cfct(idx));
effect_6 = (PRICES.nyiso.rtm_cft_6(idx))./mean(NYISO.cfct(idx)).*(NYISO.cfct(idx));
TABLES(1,2,2) = nanmean(effect_5);
TABLES(2,2,2) = nanmean(effect_6);
idx = NYISO.Time >= datetime(2020,03,01) & NYISO.Time < datetime(2020,08,01);
effect_5 = (PRICES.nyiso.rtm_cft_5(idx) - PRICES.nyiso.rtm(idx))./mean(NYISO.cfct(idx)).*(NYISO.cfct(idx));
effect_6 = (PRICES.nyiso.rtm_cft_6(idx) - PRICES.nyiso.rtm(idx))./mean(NYISO.cfct(idx)).*(NYISO.cfct(idx));
TABLES(3,1,2) = nanmean(effect_5);
TABLES(4,1,2) = nanmean(effect_6);
effect_5 = (PRICES.nyiso.rtm_cft_5(idx))./mean(NYISO.cfct(idx)).*(NYISO.cfct(idx));
effect_6 = (PRICES.nyiso.rtm_cft_6(idx))./mean(NYISO.cfct(idx)).*(NYISO.cfct(idx));
TABLES(3,2,2) = nanmean(effect_5);
TABLES(4,2,2) = nanmean(effect_6);

table({'RTM, No Nuke RR, 12 Months';'RTM, Nuke RR, 12 Months';'RTM, No Nuke RR, 6 Months';'RTM, Nuke RR, 6 Months'},-TABLES(:,1,2),-TABLES(:,1,2)./TABLES(:,2,2))

%Market impacts?
TABLES = nan(4,2,2);

idx = NYISO.Time >= datetime(2020,03,01) & NYISO.Time < datetime(2021,03,01); 
effect_5 = (PRICES.nyiso.dam_cft_5(idx).*NYISO.cfct(idx) - PRICES.nyiso.dam(idx).*NYISO.fcst(idx));
effect_6 = (PRICES.nyiso.dam_cft_6(idx).*NYISO.cfct(idx) - PRICES.nyiso.dam(idx).*NYISO.fcst(idx));
TABLES(1,1,1) = nansum(effect_5)/1e6;
TABLES(1,2,1) = nansum(PRICES.nyiso.dam_cft_5(idx).*NYISO.cfct(idx))/1e6;
TABLES(2,1,1) = nansum(effect_6)/1e6;
TABLES(2,2,1) = nansum(PRICES.nyiso.dam_cft_6(idx).*NYISO.cfct(idx))/1e6;

idx = NYISO.Time >= datetime(2020,03,01) & NYISO.Time < datetime(2020,08,01); 
effect_5 = (PRICES.nyiso.dam_cft_5(idx).*NYISO.cfct(idx) - PRICES.nyiso.dam(idx).*NYISO.fcst(idx));
effect_6 = (PRICES.nyiso.dam_cft_6(idx).*NYISO.cfct(idx) - PRICES.nyiso.dam(idx).*NYISO.fcst(idx));
TABLES(3,1,1) = nansum(effect_5)/1e6;
TABLES(3,2,1) = nansum(PRICES.nyiso.dam_cft_5(idx).*NYISO.cfct(idx))/1e6;
TABLES(4,1,1) = nansum(effect_6)/1e6;
TABLES(4,2,1) = nansum(PRICES.nyiso.dam_cft_6(idx).*NYISO.cfct(idx))/1e6;

table({'DAM, No Nuke RR, 12 Months';'DAM, Nuke RR, 12 Months';'DAM, No Nuke RR, 6 Months';'DAM, Nuke RR, 6 Months'},-TABLES(:,1,1),-TABLES(:,1,1)./TABLES(:,2,1))


idx = NYISO.Time >= datetime(2020,03,01) & NYISO.Time < datetime(2021,03,01); 
effect_5 = (PRICES.nyiso.rtm_cft_5(idx).*NYISO.ferr_abs_cft(idx) - PRICES.nyiso.rtm(idx).*NYISO.ferr_abs(idx));
effect_6 = (PRICES.nyiso.rtm_cft_6(idx).*NYISO.ferr_abs_cft(idx) - PRICES.nyiso.rtm(idx).*NYISO.ferr_abs(idx));
TABLES(1,1,2) = nansum(effect_5)/1e6;
TABLES(1,2,2) = nansum(PRICES.nyiso.rtm_cft_5(idx).*NYISO.ferr_abs_cft(idx))/1e6;
TABLES(2,1,2) = nansum(effect_6)/1e6;
TABLES(2,2,2) = nansum(PRICES.nyiso.rtm_cft_6(idx).*NYISO.ferr_abs_cft(idx))/1e6;

idx = NYISO.Time >= datetime(2020,03,01) & NYISO.Time < datetime(2020,08,01); 
effect_5 = (PRICES.nyiso.rtm_cft_5(idx).*NYISO.ferr_abs_cft(idx) - PRICES.nyiso.rtm(idx).*NYISO.ferr_abs(idx));
effect_6 = (PRICES.nyiso.rtm_cft_6(idx).*NYISO.ferr_abs_cft(idx) - PRICES.nyiso.rtm(idx).*NYISO.ferr_abs(idx));
TABLES(3,1,2) = nansum(effect_5)/1e6;
TABLES(3,2,2) = nansum(PRICES.nyiso.rtm_cft_5(idx).*NYISO.ferr_abs_cft(idx))/1e6;
TABLES(4,1,2) = nansum(effect_6)/1e6;
TABLES(4,2,2) = nansum(PRICES.nyiso.rtm_cft_6(idx).*NYISO.ferr_abs_cft(idx))/1e6;

table({'RTM, No Nuke RR, 12 Months';'RTM, Nuke RR, 12 Months';'RTM, No Nuke RR, 6 Months';'RTM, Nuke RR, 6 Months'},-TABLES(:,1,2),-TABLES(:,1,2)./TABLES(:,2,2))

idx = NYISO.Time >= datetime(2020,03,01) & NYISO.Time < datetime(2021,03,01); 
sum(abs(NYISO.LOCKDOWN(idx)))./sum(abs(NYISO.LOCKDOWN(idx))+abs(NYISO.GAS(idx))+abs(NYISO.NUKE(idx)))
sum(abs(NYISO.GAS(idx)))./sum(abs(NYISO.LOCKDOWN(idx))+abs(NYISO.GAS(idx))+abs(NYISO.NUKE(idx)))
sum(abs(NYISO.NUKE(idx)))./sum(abs(NYISO.LOCKDOWN(idx))+abs(NYISO.GAS(idx))+abs(NYISO.NUKE(idx)))

sum(abs(NYISO.LOCKDOWN(idx)))./sum(abs(NYISO.LOCKDOWN(idx))+abs(NYISO.GAS(idx))+abs(NYISO.NUKE(idx))+abs(NYISO.ERR(idx)))
sum(abs(NYISO.GAS(idx)))./sum(abs(NYISO.LOCKDOWN(idx))+abs(NYISO.GAS(idx))+abs(NYISO.NUKE(idx))+abs(NYISO.ERR(idx)))
sum(abs(NYISO.NUKE(idx)))./sum(abs(NYISO.LOCKDOWN(idx))+abs(NYISO.GAS(idx))+abs(NYISO.NUKE(idx))+abs(NYISO.ERR(idx)))
sum(abs(NYISO.ERR(idx)))./sum(abs(NYISO.LOCKDOWN(idx))+abs(NYISO.GAS(idx))+abs(NYISO.NUKE(idx)+abs(NYISO.ERR(idx))))


%% Figures Section 2 - History -- Demand & prices
clear
project_root = setup_paths;
clc
load(fullfile(project_root,'data','NEWYORK.mat'))
C = linspecer(6);

LIST = setdiff((1:15),[5 12 13 14]);
Y_LOAD = [];
Y_PRICE = [];
for i=1:11
    idx = find(ZONELOAD(i).TIME>=datetime(2014,01,01) & ZONELOAD(i).TIME<=datetime(2021,03,01));    
Y_LOAD = [Y_LOAD,ZONELOAD(i).LOAD(idx)];
idx2 = find(DAM(LIST(i)).Time>=datetime(2014,01,01) & DAM(LIST(i)).Time<=datetime(2021,03,01));    
Y_PRICE = [Y_PRICE,DAM(LIST(i)).Prices(idx2)];
 
end

TIME = ZONELOAD(i).TIME(idx);
LOAD = sum(Y_LOAD,2);
PRICE = sum(Y_LOAD.*Y_PRICE./repmat(sum(Y_LOAD,2),1,11),2);
PRICE_x = (1:length(PRICE))';

idx = find(isnan(PRICE) | isnan(LOAD));
TIME(idx) = [];
PRICE(idx) = [];
LOAD(idx) = [];

r=ksr((1:length(PRICE)),PRICE,300,length(PRICE));
figure(1)
plot(TIME,r.f,'-','color',C(2,:),'linewidth',2)
hold on
b0 = find(TIME>datetime(2015,1,1) & TIME<datetime(2020,1,1));
[B,BINT] = regress(PRICE(b0),[ones(length(PRICE(b0)),1),(1:length(PRICE(b0)))']);
plot(TIME,[ones(length(PRICE),1),(1:length(PRICE))']*B,'color',C(1,:),'linewidth',2)
plot([datetime(2020,3,1) datetime(2020,3,1)],[0 300],'--k','color',C(4,:),'linewidth',1.1)
ylim([0 100])
xlim([datetime(2015,1,1) datetime(2021,3,1)])
hold off
legend('Smoothed price series','Pre-crisis linear trend (2015-2019)','1st reported COVID-19 case in NY') %'Day-ahead prices','
set(gca,'FontSize',14)
set(legend,'Location','southwest')
ylabel('Day-ahead prices ($/MWh)')
saveas(1,['RESULTS/FIGURES/plot_PRICES.eps'],'epsc')


r=ksr((1:length(TIME)),LOAD,300,length(TIME));
figure(2)
%plot(TIME,LOAD/1000,':','color',[13 13 13]/255,'linewidth',0.001)
plot(TIME,r.f/1000,'-','color',C(2,:),'linewidth',2)
hold on
b0 = find(TIME>datetime(2015,1,1) & TIME<datetime(2020,1,1));
[B,BINT] = regress(LOAD(b0)/1000,[ones(length(LOAD(b0)),1),(1:length(LOAD(b0)))']);
plot(TIME,[ones(length(LOAD),1),(1:length(LOAD))']*B,'color',C(1,:),'linewidth',2)
plot([datetime(2020,3,1) datetime(2020,3,1)],[0 300],'--k','color',C(4,:),'linewidth',1.1)
%plot([datetime(2020,3,22) datetime(2020,3,22)],[0 300],'--k','color',C(5,:),'linewidth',1.1)
ylim([14 23.6])
xlim([datetime(2015,1,1) datetime(2021,3,1)])
hold off
legend('Smoothed load series','Pre-crisis linear trend (2015-2019)','1st reported COVID-19 case in NY') %'Actual load',
set(gca,'FontSize',14)
set(legend,'Location','southwest')
ylabel('Demand (GWh)')
saveas(2,['RESULTS/FIGURES/plot_LOADseries.eps'],'epsc')

%% Figure: demand reductions by zone

C =[168 197 57;...
254 221 63;...
159 85 156;...
225 142 188
21 158 206;...
246 146 36;...
236 81 82;...
58 175 153;...
171 171 171;...
104 106 176;...
182 129 74
]/255;
spar = 21
Data = [smooth(LOAD.west.cerr,24*spar)'; ...
    smooth(LOAD.genese.cerr,24*spar)'; ...
    smooth(LOAD.centrl.cerr,24*spar)'; ...
    smooth(LOAD.north.cerr,24*spar)'; ...
    smooth(LOAD.mhkvl.cerr,24*spar)'; ...
    smooth(LOAD.capitl.cerr,24*spar)'; ...
    smooth(LOAD.hudvl.cerr,24*spar)'; ...
    smooth(LOAD.millwd.cerr,24*spar)';...
     smooth(LOAD.dunwod.cerr,24*spar)';...
     smooth(LOAD.nyc.cerr,24*spar)';...
     smooth(LOAD.longil.cerr,24*spar)';...
   ]';

pos = Data;
pos(pos<0)=nan;
neg = -Data;
neg(neg<0)=nan;

f = figure(1)
a1 = area(NYISO.Time,pos)
hold on
a2 = area(NYISO.Time,-neg)
xline(datetime(2020,03,01))
hold off
xlim([datetime(2019,10,1) datetime(2021,02,28)])

for i=1:11
a1(i).FaceColor = C(i,:);
a2(i).FaceColor = C(i,:);
end
ylabel('Demand reductions (MWh)')
legend('West','Genesee','Central','North','Mohawk Valley','Capital','Hudson Valley','Millwood','Dunwoodie','NYC','Long Island','location','best')
set(gca,'Fontsize',14)

f.Position = [100 100 800 400];

saveas(1,['RESULTS/FIGURES/plot_loadreductionsbyzone.eps'],'epsc')


 