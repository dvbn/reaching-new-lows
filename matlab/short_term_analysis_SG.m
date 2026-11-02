project_root = setup_paths;
% File: short_term_analysis_SG.m
% 
%   Modified version of short_term_analysis.m
% 
% 
% ----------------------------------------------------------------------------------------------- %
%%   Read data                                                                                    %
% ----------------------------------------------------------------------------------------------- %
clear
project_root = setup_paths;
clc
close all

% Set path
addpath('fct');
addpath('../data');
addpath('../results');

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
    index = year(LOAD.(ZONE_LIST{zone}).Time) <= 2019;
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

% Create STRUCT with weather observations (by station)
WEATHER_LIST = dir('../data/weather-station-*.csv');
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

% Clean workspace
clearvars -EXCEPT TT LOAD PRICES WEATHER NYISO;
project_root = setup_paths;

% ----------------------------------------------------------------------------------------------- %
%% Figure: demand reductions by zone
% ----------------------------------------------------------------------------------------------- %

C = linspecer(6);

color_map =[ ...
    168 197 57; ...
    254 221 63; ...
    159 85 156; ...
    225 142 188; ...
    21 158 206; ...
    246 146 36; ...
    236 81 82; ...
    58 175 153; ...
    171 171 171; ...
    104 106 176; ...
    182 129 74
]/255;

spar = 21;
data = [ ...
    LOAD.west.cerr ...
    LOAD.genese.cerr ...
    LOAD.centrl.cerr ...
    LOAD.north.cerr ...
    LOAD.mhkvl.cerr ...
    LOAD.capitl.cerr ...
    LOAD.hudvl.cerr ...
    LOAD.millwd.cerr...
    LOAD.dunwod.cerr...
    LOAD.nyc.cerr ...
    LOAD.longil.cerr ...
];
data = movavg(data,'simple',24*spar);
pos = data;
pos(pos<0)=nan;
neg = -data;
neg(neg<0)=nan;


figure(1);clf(1);
set(gcf,'color','white');
set(gcf,'units','inch','position',[0 0 9.0 4.5]);
hold on
a1 = area(NYISO.Time,pos);
a2 = area(NYISO.Time,-neg);
xline(datetime(2020,03,01),':','color',C(4,:),'linewidth',3.0);
hold off
for i=1:11
    a1(i).FaceColor = color_map(i,:);
    a2(i).FaceColor = color_map(i,:);
    a1(i).EdgeAlpha = 0.0;
    a2(i).EdgeAlpha = 0.0;
    a1(i).ShowBaseLine = 'off';
    a2(i).ShowBaseLine = 'off';
end
set(gca,'xlim',[datetime(2019,10,01) datetime(2021,02,28)]);
set(gca,'ylim',[-2100 600]);
set(gca,'fontsize',12);
set(gca,'box','on');
ylabel('Demand reductions (MWh)');
legend('West', ...
       'Genesee', ...
       'Central', ...
       'North', ...
       'Mohawk Valley', ...
       'Capital', ...
       'Hudson Valley', ...
       'Millwood', ...
       'Dunwoodie', ...
       'NYC', ...
       'Long Island');
legend('location','southwest');
saveas(gca,fullfile(project_root,'figures','david','plot_loadreductionsbyzone.eps'),'epsc');
close(1);

% ----------------------------------------------------------------------------------------------- %
%% Counterfactual 2: Natural gas price                                                            %
% ----------------------------------------------------------------------------------------------- %

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

    X0 = [X_treat, WEATHER.kalb_d_min.temperature<=15, WEATHER.kalb_d.temperature, ...
        ones(length(X_treat),1), X_month, X_holidays, X_wday];
    
    X = X0(index1,:);
    Y = NYISO_d.gasPrice(index1);
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

% Figure 10: Natural gas Prices
C = linspecer(6);
bb = find(NYISO.Time>=datetime(2019,1,1) & NYISO.Time<datetime(2020,3,1));
figure(1); clf(1);
set(gcf,'color','white');
hold on
plot(NYISO.Time, NYISO.gasPrice, 'color', C(2,:), 'linewidth', 2.0);
plot(NYISO.Time, NYISO.gasPrice_cft, '-.', 'color', C(1,:), 'linewidth', 2.0);
plot(NYISO.Time(bb)+days(365), NYISO.gasPrice(bb), '--', 'color', C(6,:), 'linewidth', 1.0);
xline(datetime(2020,3,01), ':', 'color', C(4,:), 'linewidth', 3.0);
plot(NYISO.Time, NYISO.gasPrice, 'color', C(2,:), 'linewidth', 2.0);
hold off
set(gca,'ylim',[-0.1 4.1]);
set(gca,'xlim',[datetime(2020,01,01) datetime(2021,03,01)]);
set(gca,'FontSize',14);
set(gca,'box','on');
legend('Observed prices', ...
       'Counterfactual prices', ...
       'Previous-year prices', ...
       '1st reported COVID-19 case in NY');
legend('location','southwest');
ylabel('T6 NY Natural Gas Price ($/MMBtu)');
saveas(gcf, fullfile(project_root,'figures','david','plot_NG.eps'),'epsc');
close(1);

% Regression table
clear TABLEVALS
ii=1;
for i = 1:2
    j=1;   
    for jj=1:3
        TABLEVALS{j,ii} = ['$',num2str(NG(i).B(jj),'%5.3f'),'$'];
        TABLEVALS{j,ii+1} = ['$(',num2str(NG(i).SE(jj),'%5.3f'),')$'];
        j=j+1;
    end    
    TABLEVALS{j,ii} = ['$',num2str(NG(i).OBS,'%5d'),'$'];
    TABLEVALS{j+1,ii} = ['$',num2str(NG(i).R2,'%1.3f'),'$'];
    ii = ii+2;
end
TABLEVALS;

ROWNAMES = {'Date $\geq$ 2020-03-01','Temp $\leq$ 15F','Temperature'};
ROWNAMES{end+1} ='Obs.';
ROWNAMES{end+1} ='$R^2$';
COLNAMES = {' ',' ',' '};
TABLE = [ ...
    '\begin{tabular*}{1\hsize}{@{\hskip\tabcolsep\extracolsep\fill}l*{4}{r}} ',...
    '\toprule ', ...
    '\multicolumn{1}{c}{} & ', ...
    '\multicolumn{2}{c}{2019-2021} & ', ...
    '\multicolumn{2}{c}{2016-2021} \\ ', ...
    '\midrule ', ...
];
for j=1:5
    TABLE = [TABLE,...
        ROWNAMES{j},' & ',TABLEVALS{j,1},' & ',TABLEVALS{j,2},' & ',TABLEVALS{j,3},' & ',TABLEVALS{j,4},' \\ ']; 
    if j==3
         TABLE = [TABLE,'\midrule ',]; 
    end
end

TABLE = [TABLE, '\bottomrule \end{tabular*}'];
fileID = fopen(fullfile(project_root,'tables','david','table_NG.tex'),'w');
fprintf(fileID,'%s',TABLE);
fclose(fileID);

% ----------------------------------------------------------------------------------------------- %
%% Nuclear generation
% ----------------------------------------------------------------------------------------------- %

load(fullfile(project_root,'data','NUKE.mat'))

NUKE.three_mile_island_1{end+1,1} = 0;
NUKE.three_mile_island_1{end,2} = {'9/20/2019'};
NUKE.three_mile_island_1{end,3} = {'Reactor defueled for permanent shutdown'};
NUKE.three_mile_island_1{end,4} = {'*'};
NUKE.three_mile_island_1{end,5} = {'1'};
NUKE.three_mile_island_1.Time(end) = datetime(2021,05,19);

NUKE.three_mile_island_1 = retime(NUKE.three_mile_island_1, 'hourly','previous');
NUKE.fitzpatrick = retime(NUKE.fitzpatrick, 'hourly','previous');
NUKE.ginna = retime(NUKE.ginna(:,[1 3]) , 'hourly','previous');
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

% Figure 11: Nuclear power
Nuke_c = NYISO.nuclear;
idx = find(NYISO.Time<datetime(2020,4,23) & NYISO.Time>=datetime(2020,3,18));
Nuke_c(idx) = NYISO.nuclear(idx) - (NYISO.ACAP_IP2(idx)/100)*1020;
idx = find(NYISO.Time>=datetime(2020,4,24));
Nuke_c(idx) = NYISO.nuclear(idx) + (1-NYISO.ACAP_IP2(idx)/100)*1020;
index1 = NYISO.Time >= datetime(2020,01,01) & NYISO.Time < datetime(2021,03,01);
index2 = NYISO.Time >= datetime(2019,01,01) & NYISO.Time < datetime(2020,03,01);
figure(1); clf(1);
set(gcf,'color','white');
hold on
plot(NYISO.Time(index1), NYISO.nuclear(index1), 'color', C(2,:), 'linewidth', 2.0);
plot(NYISO.Time(index1), Nuke_c(index1), '-.', 'color', C(1,:), 'linewidth', 2.0);
plot(NYISO.Time(index2)+days(365), NYISO.nuclear(index2), '--', 'color', C(6,:), 'linewidth', 1.0);
xline(datetime(2020,3,01), ':', 'color', C(4,:), 'linewidth', 3.0);
plot(NYISO.Time(index1),NYISO.nuclear(index1),'color',C(2,:),'linewidth', 2.0);
hold off
set(gca,'xlim',[datetime(2020,01,01) datetime(2021,03,01)]);
set(gca,'ylim',[2400 6100]);
set(gca,'FontSize',14);
set(gca,'box','on');
legend('Observed generation', ...
       'Counterfactual generation', ...
       'Previous-year generation', ...
       '1st reported COVID-19 case in NY');
legend('location','southeast');
ylabel('Nuclear generation (MWh)');
saveas(gcf, fullfile(project_root,'figures','david','plot_NUKE.eps'),'epsc');
close(1);

% Don't erase what follows.
% Refueling outages of power plants in the US
%Indian point 2 - 1020MW - retired on April 30, 2020: https://www.powermag.com/indian-point-unit-2-will-shut-down-april-30/
%From March 18 to April 30, Indian Point 2 goes from 1020MW to 70% of that. Then shuts down permanently.
	
% Feb 13, 2020
% Nine Mile Point 2	94		COASTDOWN TO REFUELING OUTAGE	 	 
% 
% March 4, 2020
% Nine Mile Point 2	88		COASTDOWN TO REFUELING OUTAGE
% Nine Mile Point 2	0	3/4/2020	MANUAL REACTOR TRIP - SEE EN# 54562	*	1
% 
% March 18, 2020
% Indian Point 2	99		COASTDOWN TO DEFUELING	*
% 
% March 28, 2020
% Ginna	98		COASTDOWN TO REFUELING OUTAGE	*	
% Indian Point 2	91		COASTDOWN TO DEFUELING	*	
% Nine Mile Point 2	0	3/4/2020	REFUELING OUTAGE
% 
% April 03, 2020
% Indian Point 2	87		COASTDOWN TO DEFUELING		
% Nine Mile Point 2	18		NOT SYNCED TO GRID	*	
% Ginna	94		COASTDOWN TO REFUELING OUTAGE	*
% 
% April 07, 2020
% Ginna	0	4/5/2020	REFUELING OUTAGE	*	
% Indian Point 2	84		COASTDOWN TO DEFUELING		
% Nine Mile Point 2	55		HOLDING FOR TESTING
% 
% April 30, 2020
% Indian Point 2	70		COASTDOWN TO DEFUELING
% Ginna	0	4/5/2020	REFUELING OUTAGE
% Nine Mile Point 1	100				
% Nine Mile Point 2	100	
% 
% May 1, 2020
% Ginna	0	4/5/2020	REFUELING OUTAGE
% Indian Point 2	0	4/30/2020	SHUTDOWN FOR PERMANENT DEFUELING	*
%September: Fitzpatrick

% ----------------------------------------------------------------------------------------------- %
%% Forecast errors
% ----------------------------------------------------------------------------------------------- %

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


%Errors
Y = NYISO.ferr;
[EstCoeffCov,SE,Bhat] =  hac(X_datetime(index2,:),Y(index2),'intercept',true,'bandwidth',24*1,'display','off');
Bhat = [Bhat(2:end);Bhat(1)];
SE = [SE(2:end);SE(1)];
COV = EstCoeffCov(2:17,2:17);
table([Bhat(1:14);nan;Bhat(15:end)],[SE(1:14);nan;SE(15:end)])
SST = sum((Y(index2)-mean(Y(index2))).^2);
SSR = sum((Y(index2) - [X_datetime(index2,:),ones(sum(index2),1)]*Bhat).^2);
R2 = 1-SSR/SST;

FERR(2).Info = 'Errors';
FERR(2).B = Bhat;
FERR(2).SE = SE;
FERR(2).COV = COV;
FERR(2).t = FERR(2).B./FERR(2).SE;
FERR(2).R2 = R2;
FERR(2).OBS = sum(index2);
FERR(2).MSE = SSR/sum(index2);

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

%warning of rank defficiency will prompt -- no worries, dummies w/o
%observations (due to resampling) are automatically discarded from estimation in glmfit.
for bb=1:1000 %bootstrap loop
    idx_b= randi(J,J,1);
    [a,b] = ismember(LIST(idx_b),TIME);
    for j=1:(23) %autocorrelation robust
        b = [b,b(:,end)+1];
    end
    idx_b = b(:);
    idx_b = idx_b(1:sum(index2));
    idx_b = idx(idx_b);

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

% ----------------------------------------------------------------------------------------------- %
%% Forecast errors regression - figures
% ----------------------------------------------------------------------------------------------- %
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



% Figure 7: Average effects of pandemic on forecast errors
C = linspecer(6);
figure(1); clf(1);
set(gcf,'color','white');
hold on
plot(TT.Time,TT.BABS,'-','color',C(2,:),'linewidth',2.0);
fill([TT.Time(:); flipud(TT.Time(:))]', [TT.ICABS_U; flipud(TT.ICABS_L)]', C(2,:), ...
    'FaceAlpha', 0.2, 'EdgeColor', 'none');
plot(Time(2:end-1),BABS(2:end-1), 'd', 'color', C(1,:), 'linewidth',1.5);
xline(datetime(2020,3,01),':','color',C(4,:),'linewidth',3.0);
yline(1,':','color',[0.0;0.0;0.0;0.5],'LineWidth',1.5);
hold off
set(gca,'ylim',[-220 820]);
set(gca,'xlim',[datetime(2020,1,15) datetime(2021,2,15)]);
set(gca,'FontSize',18);
set(gca,'box','on');
legend('Spline interpolation', ...
       '95% Confidence interval', ...
       'Point estimates', ...
       '1st reported COVID-19 case in NY');
legend('location','northeast');
legend('box','on');
ylabel('Absolute forecast errors (ATE, MWh)');
saveas(gcf, fullfile(project_root,'figures','david','plot_FERR_ABS.eps'),'epsc');


figure(2); clf(2);
set(gcf,'color','white');
hold on
plot(TT.Time,TT.BBIAS,'-','color',C(2,:),'linewidth',2.0);
fill([TT.Time(:); flipud(TT.Time(:))]', [TT.ICBIAS_U; flipud(TT.ICBIAS_L)]', C(2,:), ...
    'FaceAlpha', 0.2, 'EdgeColor', 'none');
plot(Time(2:end-1),BBIAS(2:end-1),'d','color',C(1,:),'linewidth',1.5);
xline(datetime(2020,3,01),':','color',C(4,:),'linewidth',3.0);
yline(1,':','color',[0.0;0.0;0.0;0.5],'LineWidth',1.5);
hold off
set(gca,'ylim',[-1040 440]);
set(gca,'xlim',[datetime(2020,1,15) datetime(2021,2,15)]);
set(gca,'FontSize',18);
set(gca,'box','on');
legend('Spline interpolation', ...
       '95% Confidence interval', ...
       'Point estimates', ...
       '1st reported COVID-19 case in NY');
legend('location','southeast');
legend('box','on');
ylabel('Forecast errors (ATE, MWh)');
saveas(gcf, fullfile(project_root,'figures','david','plot_FERR_BIA.eps'),'epsc');


figure(3); clf(3);
set(gcf,'color','white');
hold on
plot(TT.Time,sqrt(TT.BVAR),'-','color',C(2,:),'linewidth',2.0)
fill([TT.Time(:); flipud(TT.Time(:))]', [sqrt(TT.ICVAR_U); flipud(sqrt(TT.ICVAR_L))]', C(2,:), ...
    'FaceAlpha', 0.2, 'EdgeColor', 'none');
plot(Time(2:end-1),sqrt(BVAR(2:end-1)),'d','color',C(1,:),'linewidth',1.5)
xline(datetime(2020,3,01),':','color',C(4,:),'linewidth',3.0);
yline(1,':','color',[0.0;0.0;0.0;0.5],'LineWidth',1.5);
hold off
set(gca,'ylim',[0.40 4.10]);
set(gca,'xlim',[datetime(2020,1,15) datetime(2021,2,15)]);
set(gca,'FontSize',18);
set(gca,'box','on');
legend('Spline interpolation', ...
       '95% Confidence interval', ...
       'Point estimates', ...
       '1st reported COVID-19 case in NY');
legend('location','northeast');
legend('box','on');
ylabel('Std. of forecast errors (ATE)');
saveas(gcf, fullfile(project_root,'figures','david','plot_FERR_VAR.eps'),'epsc');

% ----------------------------------------------------------------------------------------------- %
%% New counterfactual F.errs
% ----------------------------------------------------------------------------------------------- %

clear Y YY XX X_datetime Bhat SE R2 SST SSR dev stats LIST J TIME EstCoeffCov

index5 = NYISO.Time >= datetime(2020,01,01) & NYISO.Time < datetime(2021,03,01); %Jan 2020 to Mar 2021
index6 = NYISO.Time >= datetime(2019,01,01) & NYISO.Time < datetime(2020,03,01); %Jan 2019 to Mar 2020

NYISO.FERR_mean = zeros(size(NYISO.ferr));
NYISO.FERR_var = ones(size(NYISO.ferr));

NYISO.FERR_mean(index5) = TT.BBIAS;
NYISO.FERR_var(index5) = TT.BVAR;

ferr_hat = (NYISO.ferr(index5) - NYISO.FERR_mean(index5));
ferr_hat = ferr_hat ./ sqrt(NYISO.FERR_var(index5));

FERR(5).info = 'Contrefactual forecast errors';
FERR(5).time = NYISO.Time(index5);
FERR(5).cft = ferr_hat;


% Figure 12b: Density of actual, past, and counterfactual forecast errors
xi = linspace(-3000,3000,10000);
f0 = ksdensity(ferr_hat,xi);            % Counterfactual
f1 = ksdensity(NYISO.ferr(index5),xi);  % Current year
f2 = ksdensity(NYISO.ferr(index6),xi);  % Previous year
C = linspecer(6);
figure(1); clf(1);
set(gcf,'color','white');
hold on
plot(xi,f1,'-','color',C(2,:),'linewidth',2.0);
plot(xi,f0,'-.','color',C(1,:),'linewidth',2.0);
plot(xi,f2,'--','color',C(6,:),'linewidth',2.0);
xline(0,':','color',[0.0;0.0;0.0;0.5],'LineWidth',1.5);
hold off
set(gca,'xlim',[-3200 3200]);
set(gca,'yticklabels',{});
set(gca,'Fontsize',14);
set(gca,'box','on');
legend('Observed errors', ...
       'Counterfactual errors', ...
       'Previous-year errors');
legend('Location','northeast');
legend('box','on');
ylabel('Density');
xlabel('Forecast errors (MWh)');
saveas(gcf, fullfile(project_root,'figures','david','plot_DENS_FERR.eps'),'epsc');


% Figure 12a: Load forecast errors
idx = find(index5==1);
idx2 = find(index3==1);
idx3 = find(index6==1);
smoothing_window = 24*7;
ferr_smooth = movavg(NYISO.ferr, 'simple', smoothing_window);
ferr_hat_smooth = movavg(ferr_hat, 'simple', smoothing_window);
figure(2); clf(2);
set(gcf,'color','white');
hold on
plot(NYISO.Time(idx2), ferr_smooth(idx2), '-', 'color', C(2,:), 'linewidth', 2.0);
plot(NYISO.Time(idx), ferr_hat_smooth, '-.', 'color', C(1,:), 'linewidth', 2.0);
plot(NYISO.Time(idx3)+days(365), ferr_smooth(idx3), '--','color', C(6,:), 'linewidth', 1.0);
xline(datetime(2020,3,01),':','color',C(4,:),'linewidth',3.0);
yline(0,':','color',[0.0;0.0;0.0;0.5],'LineWidth',1.5);
plot(NYISO.Time(idx2), ferr_smooth(idx2), '-', 'color', C(2,:), 'linewidth', 2.0);
hold off
set(gca,'ylim',[-1250 850]);
set(gca,'xlim',[datetime(2020,1,1) datetime(2021,3,1)]);
set(gca,'FontSize',14);
set(gca,'box','on');
legend('Observed errors', ...
       'Counterfactual errors', ...
       'Previous-year errors', ...
       '1st reported COVID-19 case in NY');
legend('Location','northeast');
legend('box','on');
ylabel('Forecast errors (MWh)');
saveas(gcf, fullfile(project_root,'figures','david','plot_CFT_FERR.eps'),'epsc');


%% Regression results forecast errors
clear TABLEVALS
ii=1;
for i = 1:3 %1:size(TABLE_REG_DAM2.B,2)
    j=1;   
    for jj=1:16
        TABLEVALS{j,ii} = ['$',num2str(FERR(i).B(jj),'%6.2f'),'$'];
        if i~=3
            TABLEVALS{j,ii+1} = ['$(',num2str(FERR(i).SE(jj),'%0.2f'),')$'];
        else
            TABLEVALS{j,ii+1} = ['$[',num2str(FERR(i).SE(jj),'%0.3f'),']$'];  
        end
        j=j+1;
    end

    for jj=1:9
        TABLEVALS{j,ii} = ['$',num2str(FERR(i).B(end-9+jj),'%6.2f'),'$'];
        if i~=3
            TABLEVALS{j,ii+1} = ['$(',num2str(FERR(i).SE(end-9+jj),'%0.2f'),')$'];
        else
            TABLEVALS{j,ii+1} = ['$[',num2str(FERR(i).SE(end-9+jj),'%0.3f'),']$'];  
        end
        j=j+1;
    end  
    TABLEVALS{j,ii} = ['$',num2str(FERR(i).OBS,'%0.0f'),'$'];
    TABLEVALS{j+1,ii} = ['$',num2str(FERR(i).R2,'%0.2f'),'$'];
    ii = ii+2;
end
TABLEVALS

%ROWNAMES = cellstr(datestr(unique(NYISO.Time(index3) - day(NYISO.Time(index3)) +day(1) - hours(hour(NYISO.Time(index3)))),'yyyy-mmm'));
ROWNAMES = { ...
    '$2020-Jan$', ...
    '$2020-Feb$', ...
    '$2020-Mar$ (1-15)', ...
    '$2020-Mar$ (16-22)', ...
    '$2020-Mar$ (23-31)', ...
    '$2020-Apr$', ...
    '$2020-May$', ...
    '$2020-Jun$', ...
    '$2020-Jul$', ...
    '$2020-Aug$', ...
    '$2020-Sep$', ...
    '$2020-Oct$', ...
    '$2020-Nov$', ...
    '$2020-Dec$', ...
    '$2021-Jan$', ...
    '$2021-Feb$', ...
    '$CoolingDeg.$', ...
    '$HeatingDeg.$', ...
    '$Snowy$', ...
    '$Cloudy$', ...
    '$Windy$', ...
    '$Drizzly$', ...
    '$Rainy$', ...
    '$Fair$', ...
    '$Foggy$', ...
    'Obs.', ...
    '$R^2$', ...
};

TABLE = [ ...
    '\begin{tabular*}{1\hsize}{@{\hskip\tabcolsep\extracolsep\fill}l*{6}{r}} ', ...
    '\toprule ', ...
    '\multicolumn{1}{c}{} & ', ...
    '\multicolumn{2}{c}{Abs.Ferr.} & ', ...
    '\multicolumn{2}{c}{Ferr.} & ', ...
    '\multicolumn{2}{c}{Var.} \\ ', ...
    '\midrule ', ...
];
for j=1:length(TABLEVALS)
    TABLE = [TABLE, ...
        ROWNAMES{j}, ' & ', ...
        TABLEVALS{j,1}, ' & ', ...
        TABLEVALS{j,2}, ' & ', ...
        TABLEVALS{j,3}, ' & ', ...
        TABLEVALS{j,4}, ' & ', ...
        TABLEVALS{j,5}, ' & ', ...
        TABLEVALS{j,6}, ' \\ ', ...
    ]; 

    % For weather covariates
    if j==16
        TABLE = [TABLE, ' [5pt] '];
    end

    % For regression information
    if j==25
         TABLE = [TABLE,' \midrule ',]; 
    end
end
TABLE = [TABLE, '\bottomrule \end{tabular*}'];

% Print table
fileID = fopen(fullfile(project_root,'tables','david','table_REGFERR.tex'),'w');
fprintf(fileID,'%s',TABLE);
fclose(fileID);


% ----------------------------------------------------------------------------------------------- %
%% Day-ahead market
% ----------------------------------------------------------------------------------------------- %
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
    DAM(i).Cov = COVB2(2:3,2:3);
    DAM(i).R2 = R2;
    DAM(i).OBS = sum(index);
    DAM(i).RMSE = sqrt(mean((Y(index)- [ones(sum(index),1),X(index,:)]*B).^2));
     DAM(i).RMSE
    % plug-in bandwidth implies 15 lags for HAC matrix
end


% Figure 8: Observed and predicted day-ahead prices
C = linspecer(6);
smoothing_window = 24 * 14;
Y_smooth = movavg(Y(index2), 'simple', smoothing_window);
Xbeta_smooth = movavg([ones(sum(index2),1) X(index2,:)]*DAM(3).B, 'simple', smoothing_window);
figure(1); clf(1);
set(gcf,'color','white');
hold on
plot(NYISO.Time(index2), Y_smooth, '-', 'color', C(2,:), 'linewidth', 2.0);
plot(NYISO.Time(index2), Xbeta_smooth, '-.', 'color', C(1,:), 'linewidth', 2.0);
xline(datetime(2020,03,01),':','color',C(4,:),'linewidth',3.0);
plot(NYISO.Time(index2), Y_smooth, '-', 'color', C(2,:), 'linewidth', 2.0);
hold off
set(gca,'yscale','log');
set(gca,'ylim',[0 200]);
set(gca,'ytick',[10 50 100 150]);
set(gca,'FontSize',14);
set(gca,'box','on');
legend('Observed prices', ...
       'Predicted prices', ...
       '1st reported COVID-19 case in NY');
legend('Location','northeast');
ylabel('Day-ahead prices ($/MWh, logscale)');
saveas(gcf, fullfile(project_root,'figures','david','plot_DAM_FIT.eps'),'epsc');
    
    
%% Regression results DAM
% Second-stage
clear TABLEVALS
ii=1;
for i = 1:3 %1:size(TABLE_REG_DAM2.B,2)
    j=1;   
    for jj=2:4
        TABLEVALS{j,ii} = ['$',num2str(DAM(i).B(jj),'%6.3f'),'$'];
        if ii==5
            TABLEVALS{j,ii+1} = ['$(',num2str(DAM(i).SE(jj),'%6.3f'),')$'];
        else
            TABLEVALS{j,ii+1} = ['$(',num2str(DAM(i).SE(jj),'%6.3f'),')\quad$'];
        end
        j=j+1;
    end    
    TABLEVALS{j,ii} = ['$',num2str(DAM(i).OBS,'%d'),'$'];
    TABLEVALS{j+1,ii} = ['$',num2str(DAM(i).R2,'%4.3f'),'$'];
    ii = ii+2;
end

ROWNAMES = {'$\overline{D}-N-R$','$NG$', '$N$'};
ROWNAMES{end+1} ='Obs.';
ROWNAMES{end+1} ='$R^2$';
COLNAMES = {' ',' ',' '};
TABLE = [ ...
    '\begin{tabular*}{1\hsize}{@{\hskip\tabcolsep\extracolsep\fill}l*{6}{r}} ', ...
    '\toprule ', ...
    '\multicolumn{1}{c}{} & ', ...
    '\multicolumn{2}{c}{GMM (1)} & ', ...
    '\multicolumn{2}{c}{IV-GMM (2)} & ', ...
    '\multicolumn{2}{c}{IV-GMM (3)} \\ ', ...
    '\midrule ', ...
];
for j=1:5
    TABLE = [TABLE,...
        ROWNAMES{j},' & ',TABLEVALS{j,1},' & ',TABLEVALS{j,2},' & ',TABLEVALS{j,3},' & ',TABLEVALS{j,4},' & ',TABLEVALS{j,5},' & ',TABLEVALS{j,6},' \\ ']; 
    if j==3
         TABLE = [TABLE, '\midrule ']; 
    end
end
TABLE = [TABLE, '\bottomrule \end{tabular*}'];

fileID = fopen(fullfile(project_root,'tables','david','table_REGDAM.tex'),'w');
fprintf(fileID,'%s',TABLE);
fclose(fileID);

%First-stages
clear TABLEVALS
ii=1;
for i = 1:3 %1:size(TABLE_REG_DAM2.B,2)
    j=1;   
    for jj=2:4
        TABLEVALS{j,ii} = ['$',num2str(DAM(3).FS(i).B(jj),'%6.3f'),'$'];
        if ii==5
            TABLEVALS{j,ii+1} = ['$(',num2str(DAM(3).FS(i).SE(jj),'%6.3f'),')$'];
        else    
            TABLEVALS{j,ii+1} = ['$(',num2str(DAM(3).FS(i).SE(jj),'%6.3f'),')\quad$'];
        end
        j=j+1;
    end    
    TABLEVALS{j,ii} = ['$',num2str(DAM(3).FS(i).OBS,'%d'),'$'];
    TABLEVALS{j+1,ii} = ['$',num2str(DAM(3).FS(i).R2,'%4.3f'),'$'];
    ii = ii+2;
end

ROWNAMES = {'$(Temp-65)^2$','$NG$ (Henry Hub)', '$NuclearCap.$'};
ROWNAMES{end+1} ='Obs.';
ROWNAMES{end+1} ='$R^2$';
COLNAMES = {' ',' ',' '};
TABLE = [ ...
    '\begin{tabular*}{1\hsize}{@{\hskip\tabcolsep\extracolsep\fill}l*{6}{r}} ', ...
    '\toprule ', ...
    '\multicolumn{1}{c}{} & ', ...
    '\multicolumn{2}{c}{$\overline{D}-N-R$} & ', ...
    '\multicolumn{2}{c}{$NG$} & ', ...
    '\multicolumn{2}{c}{$N$} \\ ', ...
    '\midrule ', ...
];
for j=1:5
    TABLE = [TABLE,...
        ROWNAMES{j},' & ',TABLEVALS{j,1},' & ',TABLEVALS{j,2},' & ',TABLEVALS{j,3},' & ',TABLEVALS{j,4},' & ',TABLEVALS{j,5},' & ',TABLEVALS{j,6},' \\ ']; 
    if j==3
         TABLE = [TABLE, '\midrule ']; 
    end
end
TABLE = [TABLE, '\bottomrule \end{tabular*}'];

fileID = fopen(fullfile(project_root,'tables','david','table_REGDAM_FS.tex'),'w');
fprintf(fileID,'%s',TABLE);
fclose(fileID);


% ----------------------------------------------------------------------------------------------- %
%% Real-time market
% ----------------------------------------------------------------------------------------------- %

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
RTM(i).Cov = COVB2(3:4,3:4);
RTM(i).R2 = R2;
RTM(i).OBS = sum(index);
RTM(i).RMSE = sqrt(mean((YY- XX*B).^2));

end



% Figure 9: Observed and predicted real-time prices
C = linspecer(6);
smoothing_window = 24 * 14;
Y_smooth = movavg(Y(index2), 'simple', smoothing_window);
Xbeta_smooth = movavg([ones(sum(index2),1) X(index2,:)]*B, 'simple', smoothing_window);
figure(1); clf(1);
set(gcf,'color','white');
hold on
plot(NYISO.Time(index2), Y_smooth, '-', 'color', C(2,:), 'linewidth', 2.0);
plot(NYISO.Time(index2), Xbeta_smooth, '-.', 'color', C(1,:), 'linewidth', 2.0);
xline(datetime(2020,03,01),':','color',C(4,:),'linewidth',3.0);
plot(NYISO.Time(index2), Y_smooth, '-', 'color', C(2,:), 'linewidth', 2.0);
hold off
set(gca,'yscale','log');
set(gca,'ylim',[0 200]);
set(gca,'ytick',[10 50 100 150]);
set(gca,'FontSize',14);
set(gca,'box','on');
legend('Observed prices', ...
       'Predicted prices', ...
       '1st reported COVID-19 case in NY');
legend('Location','northeast');
ylabel('Real-times prices ($/MWh, logscale)');
saveas(gcf, fullfile(project_root,'figures','david','plot_RTM_FIT.eps'),'epsc');

%% RTM Regression results
% Second-stage
clear TABLEVALS
ii=1;
for i = 1:2
    j=1;   
    for jj=2:6
        TABLEVALS{j,ii} = ['$',num2str(RTM(i).B(jj),'%6.3f'),'$'];
        TABLEVALS{j,ii+1} = ['$(',num2str(RTM(i).SE(jj),'%6.3f'),')\hspace{.5em}$'];
        j=j+1;
    end    
    TABLEVALS{j,ii} = ['$',num2str(RTM(i).OBS,'%d'),' $'];
    TABLEVALS{j+1,ii} = ['$',num2str(RTM(i).R2,'%4.3f'),'$'];
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
        TABLEVALS{j,ii} = ['$',num2str(RTM(i).B(jj),'%6.3f'),'$'];
        TABLEVALS{j,ii+1} = ['$(',num2str(RTM(i).SE(jj),'%6.3f'),')\hspace{.5em}$'];
        j=j+1;
    end    
    TABLEVALS{j,ii} = ['$',num2str(RTM(i).OBS,'%d'),' $'];
    TABLEVALS{j+1,ii} = ['$',num2str(RTM(i).R2,'%4.3f'),'$'];
    ii = ii+2;
end

for i=5:8
TABLEVALS{5,i} = TABLEVALS{4,i};
TABLEVALS{4,i} = TABLEVALS{3,i};
TABLEVALS{3,i} = TABLEVALS{2,i};
TABLEVALS{2,i} = ' ';
end

for i=1:size(TABLEVALS,1)-2
    TABLEVALS{i,end} = replace(TABLEVALS{i,end},'\hspace{.5em}','');
end

ROWNAMES = { ...
    '$P^{DA}$', ...
    '$D - \overline{D}$', ...
    '$|\overline{D}-D|_{-}$', ...
    '$|\overline{D}-D|_{+}$', ...
    '$NG$', ...
    'Obs.', ...
    '$R^2$', ...
};

TABLE = [ ...
    '\begin{tabular*}{1\hsize}{@{\hskip\tabcolsep\extracolsep\fill}l*{9}{r}}', ...
    '\toprule', ...
    '\multicolumn{1}{c}{} & ', ...
    '\multicolumn{2}{c}{GMM (1)} & ',...
    '\multicolumn{2}{c}{IV-GMM (2)} & ', ...
    '\multicolumn{2}{c}{GMM (3)} & ', ...
    '\multicolumn{2}{c}{IV-GMM (4)} \\ ', ...
    '\midrule', ...
];
for j=1:7
    TABLE = [TABLE,...
        ROWNAMES{j},' & ',TABLEVALS{j,1},' & ',TABLEVALS{j,2},' & ',TABLEVALS{j,3},' & ',TABLEVALS{j,4},' & ',TABLEVALS{j,5},' & ',TABLEVALS{j,6},' & ',TABLEVALS{j,7},' & ',TABLEVALS{j,8},' \\ ']; 
    if j==5
        TABLE = [TABLE, '\midrule ']; 
    end
end
TABLE = [TABLE, '\bottomrule \end{tabular*}'];

fileID = fopen(fullfile(project_root,'tables','david','table_REGRTM.tex'),'w');
fprintf(fileID,'%s',TABLE);
fclose(fileID);

%First-stages
clear TABLEVALS
ii=1;
for i = 1:2 
    j=1;   
    for jj=2:5
        if jj==2 || jj==5
            TABLEVALS{j,ii} = ['$',num2str(RTM(4).FS(i).B(jj)*100,'%6.3f'),'$'];
            if ii==3
            TABLEVALS{j,ii+1} = ['$(',num2str(RTM(4).FS(i).SE(jj)*100,'%6.3f'),')$'];
            else
            TABLEVALS{j,ii+1} = ['$(',num2str(RTM(4).FS(i).SE(jj)*100,'%6.3f'),')\quad \quad$'];
            end
        else
            TABLEVALS{j,ii} = ['$',num2str(RTM(4).FS(i).B(jj),'%6.3f'),'$'];
            if ii==3
            TABLEVALS{j,ii+1} = ['$(',num2str(RTM(4).FS(i).SE(jj),'%6.3f'),')$'];
            else
            TABLEVALS{j,ii+1} = ['$(',num2str(RTM(4).FS(i).SE(jj),'%6.3f'),')\quad \quad$'];
            end
        end
        j=j+1;
    end    
    TABLEVALS{j,ii} = ['$',num2str(RTM(4).FS(i).OBS,'%d'),' $'];
    TABLEVALS{j+1,ii} = ['$',num2str(RTM(4).FS(i).R2,'%4.3f'),'$'];
    ii = ii+2;
end

ROWNAMES = { ...
    '$P^{DA}\times 100$', ...
    '$|\overline{D}^{NYC}-D^{NYC}|_{-}$', ...
    '$|\overline{D}^{NYC}-D^{NYC}|_{+}$', ...
    '$NG\times 100$', ...
    'Obs.', ...
    '$R^2$', ...
};

TABLE = [ ...
    '\begin{tabular*}{1\hsize}{@{\hskip\tabcolsep\extracolsep\fill}l*{4}{r}}', ...
    '\toprule ', ...
    '\multicolumn{1}{c}{} & ', ...
    '\multicolumn{2}{c}{$|\overline{D}-D|_{-}$} & ', ...
    '\multicolumn{2}{c}{$|\overline{D}-D|_{+}$} \\ ', ...
    '\midrule ', ...
];
for j=1:6
    TABLE = [TABLE,...
        ROWNAMES{j},' & ',TABLEVALS{j,1},' & ',TABLEVALS{j,2},' & ',TABLEVALS{j,3},' & ',TABLEVALS{j,4},' \\ ']; 
    if j==4
         TABLE = [TABLE, '\midrule ']; 
    end
end
TABLE = [TABLE, '\bottomrule \end{tabular*}'];

fileID = fopen(fullfile(project_root,'tables','david','table_REGRTM_FS.tex'),'w');
fprintf(fileID,'%s',TABLE);
fclose(fileID);     


%% Descriptive stats for the regressions DAM/RTM

b0 = NYISO.Time >= datetime(2016,01,01) & NYISO.Time < datetime(2020,01,01);
b1 = NYISO.Time >= datetime(2020,01,01) & NYISO.Time < datetime(2021,03,01);

VARS = [ ...
    PRICES.('nyiso').dam, ...
    PRICES.('nyiso').rtm, ...
    X_netfload/1000, ...
    NYISO.fcst/1000, ...
    X_nuclear, ...
    (NYISO.wind+NYISO.otherRenewables)/1000, ...
    NYISO.ferr/1000, ...
    X_gasPrice, ...
    X_gasPrice_HH, ...
    NYISO.NUKECAP, ...
    WEATHER.kalb.temperature, ...
];

TABLEDES = zeros(4,11);
TABLEDES(1,:) = nanmean(VARS(b0,:));
TABLEDES(2,:) = nanstd(VARS(b0,:));
TABLEDES(3,:) = quantile(VARS(b0,:),0.05);
TABLEDES(4,:) = quantile(VARS(b0,:),0.95);
TABLEDES
TABLEDES2 = zeros(4,11);
TABLEDES2(1,:) = nanmean(VARS(b1,:));
TABLEDES2(2,:) = nanstd(VARS(b1,:));
TABLEDES2(3,:) = quantile(VARS(b1,:),0.05);
TABLEDES2(4,:) = quantile(VARS(b1,:),0.95);
TABLEDES2

TABLEDES = [TABLEDES;TABLEDES2];

clear TABLEVALS TABLEVALS2
TARGET= TABLEDES';
for i = 1:size(TARGET,1)
    for j=1:size(TARGET,2)
TABLEVALS{i,j} = ['$',num2str(TARGET(i,j),'%0.2f'),'$'];
    end
end

% ROWNAMES = { ...
%     '$P^{DA}$ (\$)', ...
%     '$P^{RT}$ (\$)', ...
%     '$\overline{D}-N-R$ (GW)', ...
%     '$\overline{D}$ (GW)', ...
%     '$N$ (GW)', ...
%     '$R$ (GW)', ...
%     '$FE$ (GW)', ...
%     '$NG$ T6NY (\$)', ...
%     '$NG$ HH (\$)', ...
%     'Nuclear Cap. (\%)', ...
%     '$Temp$ ($^{\circ}F$)', ...
% };

ROWNAMES = { ...
    '$P^{DA}$', ...
    '$P^{RT}$', ...
    '$\overline{D}-N-R$', ...
    '$\overline{D}$', ...
    '$N$', ...
    '$R$', ...
    '$FE$', ...
    '$NG$ T6NY', ...
    '$NG$ HH', ...
    '$NuclearCap.$', ...
    '$Temp$ ALB', ...
};

TABLE = [ ...
    '\begin{tabular*}{1\hsize}{@{\hskip\tabcolsep\extracolsep\fill}l*{9}{r}}', ...
    '\toprule', ... 
    '\multicolumn{1}{c}{} & ', ...
    '\multicolumn{4}{c}{Jan 1, 2016 to Dec 31, 2019} & ', ...
    '\multicolumn{4}{c}{Jan 1, 2020 to Feb 28, 2021} \\ ', ...
    '\cmidrule(lr){2-5} ', ...
    '\cmidrule(lr){6-9} ', ...
    ' & ', ...
    'Mean & Std. & $Q_{0.05}$ & $Q_{0.95}$ & ', ...
    'Mean & Std. & $Q_{0.05}$ & $Q_{0.95}$ \\ ', ...
    '\midrule ', ...
];

for i=1:size(TABLEVALS,1)
    TABLE = [TABLE,...
        ROWNAMES{i},' & ',TABLEVALS{i,1},' & ',TABLEVALS{i,2},' & ',TABLEVALS{i,3},' & ',TABLEVALS{i,4},' & ',TABLEVALS{i,5},' & ',TABLEVALS{i,6},' & ',TABLEVALS{i,7},' & ',TABLEVALS{i,8}, ' \\ '];
end
TABLE = [TABLE, ' \bottomrule \end{tabular*}'];

fileID = fopen(fullfile(project_root,'tables','david','table_DESCRREG.tex'),'w');
fprintf(fileID,'%s',TABLE);
fclose(fileID);    

% ----------------------------------------------------------------------------------------------- %
%% Counterfactual prices   
% ----------------------------------------------------------------------------------------------- %

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

PRICES.nyiso.rtm_cft_1 = PRICES.nyiso.rtm;
PRICES.nyiso.rtm_cft_1(index2) = PRICES.nyiso.rtm(index2) +(PRICES.nyiso.dam_cft_1(index2)-PRICES.nyiso.dam(index2));


% Scenario 2: No Fuel Price Drop
PRICES.nyiso.dam_cft_2 = PRICES.nyiso.dam;
PRICES.nyiso.dam_cft_2(index2) = PRICES.nyiso.dam(index2) + DAM(3).B(3)*(-NG(1).B(1));

PRICES.nyiso.rtm_cft_2 = PRICES.nyiso.rtm;
PRICES.nyiso.rtm_cft_2(index2) = PRICES.nyiso.rtm(index2) +(PRICES.nyiso.dam_cft_2(index2)-PRICES.nyiso.dam(index2));


% Scenario 3: No Nuclear Retirement
PRICES.nyiso.dam_cft_3 = PRICES.nyiso.dam;
PRICES.nyiso.dam_cft_3(index2) = PRICES.nyiso.dam(index2) + (DAM(3).B(4)-DAM(3).B(2))*(Nuke_c(index2)/1000 - NYISO.nuclear(index2)/1000);

PRICES.nyiso.rtm_cft_3 = PRICES.nyiso.rtm;
PRICES.nyiso.rtm_cft_3(index2) = PRICES.nyiso.rtm(index2) +(PRICES.nyiso.dam_cft_3(index2)-PRICES.nyiso.dam(index2));


% Scenario 4: No Abnormal F. errors
PRICES.nyiso.dam_cft_4 = PRICES.nyiso.dam;
PRICES.nyiso.rtm_cft_4 = PRICES.nyiso.rtm;

PRICES.nyiso.rtm_cft_4(index5) = PRICES.nyiso.rtm(index5) ...
    + RTM(4).B(3)*((FERR(5).cft<=0).*abs(FERR(5).cft)/1000 - (NYISO.ferr(index5)<=0).*abs(NYISO.ferr(index5))/1000) ...
    + RTM(4).B(4)*((FERR(5).cft>0).*abs(FERR(5).cft)/1000 - (NYISO.ferr(index5)>0).*abs(NYISO.ferr(index5))/1000);


% Scenario 5: No Lockdown + No Fuel Price Drop + No Nuclear RR + No Abnormal F. errors
PRICES.nyiso.dam_cft_5 = PRICES.nyiso.dam;
PRICES.nyiso.dam_cft_5(index2) = PRICES.nyiso.dam(index2) + DAM(3).B(2)*(NYISO.cfct(index2) - NYISO.fcst(index2))/1000 + DAM(3).B(3)*(-NG(1).B(1)) + (DAM(3).B(4)-DAM(3).B(2))*(Nuke_c(index2)/1000 - NYISO.nuclear(index2)/1000);

PRICES.nyiso.rtm_cft_5 = PRICES.nyiso.rtm;
PRICES.nyiso.rtm_cft_5(index5) = PRICES.nyiso.rtm(index5) + (PRICES.nyiso.dam_cft_5(index5)-PRICES.nyiso.dam(index5)) ...
    + RTM(4).B(3)*((FERR(5).cft<=0).*abs(FERR(5).cft)/1000 - (NYISO.ferr(index5)<=0).*abs(NYISO.ferr(index5))/1000) ...
    + RTM(4).B(4)*((FERR(5).cft>0).*abs(FERR(5).cft)/1000 - (NYISO.ferr(index5)>0).*abs(NYISO.ferr(index5))/1000);


% Scenario 6: No Lockdown + No Fuel Price Drop + No Abnormal F. errors
PRICES.nyiso.dam_cft_6 = PRICES.nyiso.dam;
PRICES.nyiso.dam_cft_6(index2) = PRICES.nyiso.dam(index2) ...
    + DAM(3).B(2)*(NYISO.cfct(index2) - NYISO.fcst(index2))/1000 ...
    + DAM(3).B(3)*(-NG(1).B(1));

PRICES.nyiso.rtm_cft_6 = PRICES.nyiso.rtm;
PRICES.nyiso.rtm_cft_6(index5) = PRICES.nyiso.rtm(index5) ...
    + (PRICES.nyiso.dam_cft_6(index5) - PRICES.nyiso.dam(index5)) ...
    + RTM(4).B(3)*((FERR(5).cft<=0).*abs(FERR(5).cft)/1000 - (NYISO.ferr(index5)<=0).*abs(NYISO.ferr(index5))/1000) ...
    + RTM(4).B(4)*((FERR(5).cft>0).*abs(FERR(5).cft)/1000 - (NYISO.ferr(index5)>0).*abs(NYISO.ferr(index5))/1000);

%% Figures with confidence interval

% Reshape timetable for daily average
PRICES.nyiso_d = retime(PRICES.nyiso,'daily','mean');

% Compute confidence band for day-ahead price
idx = NYISO_d.Time >= datetime(2020,01,01) & NYISO_d.Time < datetime(2021,03,01);
smoothing_window = 7;
Y_diff_smooth = movavg(NYISO_d.cfct - NYISO_d.fcst, 'simple', smoothing_window)./1000;

beta_hat = DAM(3).B(2);
delta_hat = DAM(3).B(3);
lambda_hat = -NG(1).B(1);
theta_hat = [lambda_hat delta_hat beta_hat];

sigma_Y = fzero(@(sigma_Y) mean(abs(Y_diff_smooth(~idx)) < sigma_Y)-0.68, 1.0);
sigma_beta = DAM(3).SE(2);
sigma_delta = DAM(3).SE(3);
sigma_lambda = NG(1).SE(1);
Sigma_hat = diag([sigma_beta, sigma_delta, sigma_lambda, sigma_Y].^2);
Sigma_hat([2 5]) = DAM(3).Cov(2); 

sigma_dam = zeros(sum(idx),1);
k = find(idx);
for i=1:sum(idx)
    A = [Y_diff_smooth(k(i)); theta_hat'];
    sigma_dam(i) = sqrt(A' * Sigma_hat * A);
end


% Figure 13a: DAM price with confidence band
C = linspecer(6);
Time = PRICES.nyiso_d.Time(idx);
idx_fill = Time > datetime(2020,03,01);
dam_smooth = movavg(PRICES.nyiso_d.dam, 'simple', smoothing_window);
dam_smooth_cft = movavg(PRICES.nyiso_d.dam_cft_6, 'simple', smoothing_window);
dam_smooth_cft = dam_smooth_cft(idx);
dam_smooth_cft_ub = dam_smooth_cft + 1.96.*sigma_dam;
dam_smooth_cft_lb = dam_smooth_cft - 1.96.*sigma_dam;
X_fill = [Time(idx_fill)', fliplr(Time(idx_fill)')];
Y_fill = [dam_smooth_cft_lb(idx_fill)', fliplr(dam_smooth_cft_ub(idx_fill)')];
figure(1); clf(1);
set(gcf,'color','white');
hold on
plot(Time, dam_smooth(idx), '-', 'color', C(2,:), 'LineWidth', 2.0);
plot(Time(idx_fill), dam_smooth_cft(idx_fill), '-.', 'color', C(1,:), 'LineWidth', 2.0);
fill(X_fill, Y_fill, C(1,:), 'FaceAlpha', 0.2, 'EdgeAlpha', 0.0);
xline(datetime(2020,03,01),':','color',C(4,:),'linewidth',2.0);
plot(Time, dam_smooth(idx), '-', 'color', C(2,:), 'LineWidth', 2.0);
hold off
set(gca,'xlim',[datetime(2020,1,1) datetime(2021,3,1)]);
set(gca,'ylim',[5 95]);
set(gca,'Fontsize',14);
set(gca,'box','on');
legend('Observed prices', ...
       'Counterfactual prices (Scenarios 1-2-4)', ...
       '95% Confidence interval', ...
       '1st reported COVID-19 case in NY');
legend('location','northwest');
ylabel('Day-ahead price ($/MWh)');
saveas(1,fullfile(project_root,'figures','david','plot_DAprice_cft.eps'),'epsc')

%% Forecast error std (parametric bootstrap)
% Use bootstrapped value of Bhat_b for log(FERR(3).B) to compute FERR_var and sample for FERR_mean using
% asymptotic value FERR(2).B(1:16) and FERR(2).COV (shape is already of for B(1:16))
% 
Time = [datetime(2020,1,1,0,30,0),datetime(2020,1,15,0,30,0),datetime(2020,2,15,0,30,0),datetime(2020,3,7,0,30,0),datetime(2020,3,19,0,30,0),datetime(2020,3,28,0,30,0),...
    datetime(2020,4,15,0,30,0),datetime(2020,5,15,0,30,0),datetime(2020,6,15,0,30,0),datetime(2020,7,15,0,30,0),datetime(2020,8,15,0,30,0),datetime(2020,9,15,0,30,0),datetime(2020,10,15,0,30,0),...
    datetime(2020,11,15,0,30,0),datetime(2020,12,15,0,30,0),datetime(2021,1,15,0,30,0),datetime(2021,2,15,0,30,0),datetime(2021,2,29,0,30,0)];

index_bootstrap = NYISO.Time >= datetime(2020,01,01) & NYISO.Time < datetime(2021,03,01);
ferr_bootstrap = zeros(sum(index_bootstrap),1000);
for bb=1:1000
    
    BBIAS = [0;mvnrnd(FERR(2).B(1:16),FERR(2).COV)';0];
    BLVAR = [0;Bhat_b(1:16,bb)-mean(Bhat_b(1:16,:),2) + log(FERR(3).B(1:16));0];

    tmp = timetable(Time',BBIAS,BLVAR);
    tmp = retime(tmp,'hourly','mean');
    tmp = fillmissing(tmp,'spline');
    tmp(end,:) = [];
    
    FERR_mean = tmp.BBIAS;
    FERR_var = exp(tmp.BLVAR);

    ferr_bootstrap(:,bb) = (NYISO.ferr(index_bootstrap) - FERR_mean) ./ sqrt(FERR_var);
    
end

%%

% Compute covariate for real-time market price
ferr_abs_p = (abs(max(ferr_bootstrap,0)) - abs(max(NYISO.ferr(index_bootstrap),0)))./1000;
ferr_abs_m = (abs(min(ferr_bootstrap,0)) - abs(max(NYISO.ferr(index_bootstrap),0)))./1000;

% Get daily average of bootstrapped forecast errors
tmp = timetable(tmp.Time,ferr_abs_p, ferr_abs_m);
tmp = retime(tmp,'daily','mean');

% Smoothed daily average forecast errors (1 week)
ferr_abs_p = movavg(tmp.Var1, 'simple', 7);
ferr_abs_m = movavg(tmp.Var2, 'simple', 7);

% Compute bootstrapped std (smoothed daily average)
sigma_ferr_p = std(ferr_abs_p,[],2);
sigma_ferr_m = std(ferr_abs_m,[],2);


% Unpack estimates
beta_hat_p = RTM(4).B(4);
beta_hat_m = RTM(4).B(3);

% Compute real-time price std (delta-method)
sigma_rtm = zeros(sum(idx),1);
for i=1:sum(idx)
    A = [ferr_abs_m(i); ferr_abs_p(i); 1.0; beta_hat_m; beta_hat_p];
    Sigma_hat = diag([RTM(4).SE(3:4)', sigma_dam(i), sigma_ferr_m(i), sigma_ferr_p(i)].^2);
    Sigma_hat([2 6]) = RTM(4).Cov(2);
    sigma_rtm(i) = sqrt(A' * Sigma_hat * A);
end



% Figure 13b:
Time = PRICES.nyiso_d.Time(idx);
idx_fill = Time > datetime(2020,03,01);
rtm_smooth = movavg(PRICES.nyiso_d.rtm,'simple',7);
rtm_smooth_cft = movavg(PRICES.nyiso_d.rtm_cft_6,'simple',7);
rtm_smooth_cft = rtm_smooth_cft(idx);
rtm_smooth_cft_lb = rtm_smooth_cft + 1.96.*sigma_rtm;
rtm_smooth_cft_ub = rtm_smooth_cft - 1.96.*sigma_rtm;
X_fill = [Time(idx_fill)', fliplr(Time(idx_fill)')];
Y_fill = [rtm_smooth_cft_lb(idx_fill)', fliplr(rtm_smooth_cft_ub(idx_fill)')];
figure(1); clf(1);
set(gcf,'color','white');
hold on
plot(Time, rtm_smooth(idx), '-', 'color', C(2,:), 'LineWidth', 2.0);
plot(Time(idx_fill), rtm_smooth_cft(idx_fill), '-.', 'color', C(1,:), 'LineWidth', 2.0);
fill(X_fill, Y_fill, C(1,:), 'FaceAlpha', 0.2, 'EdgeAlpha', 0.0);
xline(datetime(2020,03,01),':','color',C(4,:),'linewidth',2.0);
plot(Time, rtm_smooth(idx), '-', 'color', C(2,:), 'LineWidth', 2.0);
hold off
set(gca,'xlim',[datetime(2020,1,1) datetime(2021,3,1)]);
set(gca,'ylim',[5 95]);
set(gca,'Fontsize',14);
set(gca,'box','on');
legend('Observed prices', ...
       'Counterfactual prices (Scenarios 1-2-4)', ...
       '95% Confidence interval', ...
       '1st reported COVID-19 case in NY');
legend('location','northwest');
ylabel('Real-time price ($/MWh)');
saveas(1,fullfile(project_root,'figures','david','plot_RTprice_cft.eps'),'epsc')


% ----------------------------------------------------------------------------------------------- %
%% Breaking down day-ahead impacts
% ----------------------------------------------------------------------------------------------- %

NYISO.LOCKDOWN = NYISO.cfct*0;
NYISO.GAS = NYISO.cfct*0;
NYISO.NUKE = NYISO.cfct*0;

NYISO.LOCKDOWN(index2) = -DAM(3).B(2)*(NYISO.cfct(index2) - NYISO.fcst(index2))/1000;
NYISO.GAS(index2) = ones(sum(index2),1)*DAM(3).B(3)*(NG(1).B(1));
NYISO.NUKE(index2) = -(DAM(3).B(4)-DAM(3).B(2))*(Nuke_c(index2)/1000 - NYISO.nuclear(index2)/1000);

spar = 15;
data = movavg([NYISO.LOCKDOWN NYISO.GAS NYISO.NUKE],'simple',24*spar);
pos = data;
pos(pos<0)=nan;
neg = -data;
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

% Figure 14a:
figure(1); clf(1);
set(gcf,'color','white');
hold on
a1 = area(NYISO.Time,pos);
plot(NYISO.Time(index), sum(data(index,:),2), ':r', 'LineWidth', 3.0);
a2 = area(NYISO.Time,-neg);
plot(NYISO.Time(index), sum(data(index,:),2), ':r', 'LineWidth', 3.0);
hold off
for i=1:3
    a1(i).FaceColor = C(i,:);
    a2(i).FaceColor = C(i,:);
    a1(i).FaceAlpha = 1-0.1*i;
    a2(i).FaceAlpha = 1-0.1*i;
    a1(i).EdgeAlpha = 0.0;
    a2(i).EdgeAlpha = 0.0;
    a1(i).ShowBaseLine = 'off';
    a2(i).ShowBaseLine = 'off';
end
set(gca,'xlim',[datetime(2020,03,1) datetime(2021,02,28)]);
set(gca,'ylim',[-12.4, 6.4]);
set(gca,'fontsize',14);
set(gca,'box','on');
ylabel('Day-ahead price impacts ($/MWh)')
legend('Demand Reductions', ...
       'Natural Gas Price Drop', ...
       'Nuclear Reactor Retirement', ...
       'Combined');
legend('location','southeast');
saveas(gca,fullfile(project_root,'figures','david','plot_DApriceimpacts.eps'),'epsc');
% saveas(1,['RESULTS/FIGURES/plot_DApriceimpacts.eps'],'epsc')

% ----------------------------------------------------------------------------------------------- %
%% Breaking down real-time impacts
% ----------------------------------------------------------------------------------------------- %

NYISO.ERR = NYISO.cfct*0;

NYISO.ERR(index5) = - RTM(4).B(3)*((FERR(5).cft<=0).*abs(FERR(5).cft)/1000 - (NYISO.ferr(index5)<=0).*abs(NYISO.ferr(index5))/1000) ...
    - RTM(4).B(4)*((FERR(5).cft>0).*abs(FERR(5).cft)/1000 - (NYISO.ferr(index5)>0).*abs(NYISO.ferr(index5))/1000);

spar = 15;
data = movavg([NYISO.LOCKDOWN NYISO.GAS NYISO.NUKE NYISO.ERR],'simple',24*spar);
pos = data;
pos(pos<0)=nan;
neg = -data;
neg(neg<0)=nan;

% Figure 14b: 
figure(1);clf(1);
set(gcf,'color','white');
hold on
a1 = area(NYISO.Time,pos);
plot(NYISO.Time(index), sum(data(index,:),2), ':r', 'LineWidth', 3.0);
a2 = area(NYISO.Time,-neg);
plot(NYISO.Time(index), sum(data(index,:),2), ':r', 'LineWidth', 3.0);
hold off
set(gca,'xlim',[datetime(2020,03,1) datetime(2021,02,28)]);
set(gca,'ylim',[-12.4 6.4]);
set(gca,'fontsize',14);
set(gca,'box','on');
for i=1:4
    a1(i).FaceColor = C(i,:);
    a2(i).FaceColor = C(i,:);
    a1(i).FaceAlpha = 1-0.1*i;
    a2(i).FaceAlpha = 1-0.1*i;
    a1(i).EdgeAlpha = 0.0;
    a2(i).EdgeAlpha = 0.0;
    a1(i).ShowBaseLine = 'off';
    a2(i).ShowBaseLine = 'off';
end
ylabel('Real-time price impacts ($/MWh)')
legend('Demand Reductions', ...
       'Natural Gas Price Drop', ...
       'Nuclear Reactor Retirement', ...
       'Abnormal Forecast Errors', ...
       'Combined');
legend('location','southeast');
saveas(gca,fullfile(project_root,'figures','david','plot_RTpriceimpacts.eps'),'epsc');
% saveas(1,['RESULTS/FIGURES/plot_RTpriceimpacts.eps'],'epsc')

% ----------------------------------------------------------------------------------------------- %
%% Breaking down day-ahead market impacts
% ----------------------------------------------------------------------------------------------- %

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

NYISO.REFUELING = [];
NYISO_w = retime(NYISO,'weekly','mean');
NYISO_w = retime(NYISO_w,'hourly','mean');
NYISO_w = fillmissing(NYISO_w,'previous');

spar = 3;
data = movavg(cumsum([NYISO_w.LOCKDOWN_M NYISO_w.GAS_M NYISO_w.NUKE_M]),'simple',24*spar);
pos = data;
pos(pos<0)=nan;
neg = -data;
neg(neg<0)=nan;

figure(1);clf(1);
set(gcf,'color','white');
hold on
a1 = area(NYISO_w.Time,pos/1e6);
plot(NYISO_w.Time(index),sum(data(index,:),2)/1e6,':r','LineWidth',3)
a2 = area(NYISO_w.Time,-neg/1e6);
plot(NYISO_w.Time(index),sum(data(index,:),2)/1e6,':r','LineWidth',3)
hold off
for i=1:3
    a1(i).FaceColor = C(i,:);
    a2(i).FaceColor = C(i,:);
    a1(i).FaceAlpha = 1-0.1*i;
    a2(i).FaceAlpha = 1-0.1*i;
    a1(i).EdgeAlpha = 0.0;
    a2(i).EdgeAlpha = 0.0;
    a1(i).ShowBaseLine = 'off';
    a2(i).ShowBaseLine = 'off';
end
set(gca,'xlim',[datetime(2020,03,1) datetime(2021,02,27)]);
set(gca,'ylim',[-620 320]);
set(gca,'Fontsize',14);
set(gca,'box','on');
ylabel('Cumulative day-ahead market impacts (million $)')
legend('Demand Reductions', ...
       'Natural Gas Price Drop', ...
       'Nuclear Reactor Retirement', ...
       'Combined');
legend('location','southwest');
saveas(gca,fullfile(project_root,'figures','david','plot_DAmarketimpacts.eps'),'epsc');
% saveas(1,['RESULTS/FIGURES/plot_DAmarketimpacts.eps'],'epsc')

% ----------------------------------------------------------------------------------------------- %
%% Breaking down balancing costs
% ----------------------------------------------------------------------------------------------- %

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

spar = 3;
data = [NYISO_w.LOCKDOWN_R NYISO_w.GAS_R NYISO_w.NUKE_R NYISO_w.ERR_R]; 
data = movavg(cumsum(data),'simple',24*spar);
pos = data;
pos(pos<0)=nan;
neg = -data;
neg(neg<0)=nan;


figure(1);clf(1);
set(gcf,'color','white');
hold on
hold on
a1 = area(NYISO_w.Time,pos/1e6);
plot(NYISO_w.Time(index), sum(data(index,:),2)/1e6, ':r','LineWidth',3);
a2 = area(NYISO_w.Time,-neg/1e6);
plot(NYISO_w.Time(index), sum(data(index,:),2)/1e6,':r','LineWidth',3);
hold off
for i=1:4
    a1(i).FaceColor = C(i,:);
    a2(i).FaceColor = C(i,:);
    a1(i).FaceAlpha = 1-0.1*i;
    a2(i).FaceAlpha = 1-0.1*i;
    a1(i).EdgeAlpha = 0.0;
    a2(i).EdgeAlpha = 0.0;
    a1(i).ShowBaseLine = 'off';
    a2(i).ShowBaseLine = 'off';
end
set(gca,'xlim',[datetime(2020,03,1) datetime(2021,02,27)]);
set(gca,'ylim',[-11 31]);
set(gca,'Fontsize',14);
set(gca,'box','on');
ylabel('Cumulative day-ahead market impacts (million $)')
legend('Demand Reductions', ...
       'Natural Gas Price Drop', ...
       'Nuclear Reactor Retirement', ...
       'Abnormal Forecast Errors', ...
       'Combined');
legend('location','northwest');
saveas(gca,fullfile(project_root,'figures','david','plot_RTmarketimpacts.eps'),'epsc');
% saveas(1,['RESULTS/FIGURES/plot_RTmarketimpacts.eps'],'epsc')

% ----------------------------------------------------------------------------------------------- %
%% Breaking down total impacts (not in paper)
% ----------------------------------------------------------------------------------------------- %

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


% ----------------------------------------------------------------------------------------------- %
%% Figures Section 2 - History -- Demand & prices
% ----------------------------------------------------------------------------------------------- %

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
b0 = find(TIME>datetime(2015,1,1) & TIME<datetime(2020,1,1));
[B,BINT] = regress(PRICE(b0),[ones(length(PRICE(b0)),1),(1:length(PRICE(b0)))']);
figure(1); clf(1);
set(gcf,'color','white')
hold on
plot(TIME,r.f, '-', 'color', C(2,:), 'linewidth', 2.0)
plot(TIME,[ones(length(PRICE),1),(1:length(PRICE))']*B,'--','color',C(1,:),'linewidth',2.0)
xline(datetime(2020,03,01),':','color',C(4,:),'linewidth',3.0);
hold off
set(gca,'ylim',[-2 102]);
set(gca,'xlim',[datetime(2015,1,1) datetime(2021,3,1)]);
set(gca,'fontsize',14);
set(gca,'box','on');
ylabel('Day-ahead prices ($/MWh)')
legend('Smoothed price series', ...
       'Pre-crisis linear trend (2015-2019)', ...
       '1st reported COVID-19 case in NY')
legend('Location','southwest');
saveas(gca,fullfile(project_root,'figures','david','plot_PRICES.eps'),'epsc');
% saveas(1,['RESULTS/FIGURES/plot_PRICES.eps'],'epsc')


r=ksr((1:length(TIME)),LOAD,300,length(TIME));
b0 = find(TIME>datetime(2015,1,1) & TIME<datetime(2020,1,1));
[B,BINT] = regress(LOAD(b0)/1000,[ones(length(LOAD(b0)),1),(1:length(LOAD(b0)))']);
figure(2);clf(2);
set(gcf,'color','white');
hold on
plot(TIME,r.f/1000,'-','color',C(2,:),'linewidth',2)
plot(TIME,[ones(length(LOAD),1),(1:length(LOAD))']*B,'--','color',C(1,:),'linewidth',2)
xline(datetime(2020,03,01),':','color',C(4,:),'linewidth',3.0);
hold off
set(gca,'ylim',[13.8 23.2]);
set(gca,'xlim',[datetime(2015,1,1) datetime(2021,3,1)]);
set(gca,'FontSize',14);
set(gca,'box','on');
ylabel('Demand (GWh)');
legend('Smoothed load series', ...
       'Pre-crisis linear trend (2015-2019)', ...
       '1st reported COVID-19 case in NY');
legend('Location','southwest');
saveas(gca,fullfile(project_root,'figures','david','plot_LOADseries.eps'),'epsc');
% saveas(2,['RESULTS/FIGURES/plot_LOADseries.eps'],'epsc')


 
