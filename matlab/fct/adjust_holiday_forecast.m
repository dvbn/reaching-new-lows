function Y_hat = adjust_holiday_forecast(Y_hat, Y_load, day_index, holidays_index) 
    
    nday = [3; 3; 2; ones(8,1)];        % Nb of day to adjust
    hindex = [2; 4; 5; (7:14)'];        % Index for observed date 
    % (1) New Year Eve / New Year day / Jan 2nd         (3 days)
    % (2) Christmas Eve / Christmas Day / Boxing Day    (3 days)
    % (3) Thanksgiving / Black Friday                   (2 days)
    % (4) Remaining Federal Holidays                    (1 day)

    for n=1:length(nday)
        % Get day index of holiday
        indexDay = find(holidays_index == hindex(n));
        Ind = @(dayIndex) (dayIndex-1)*24 + (-12+1:24*nday(n)+12)';

        % Prepare regression data
        Y_error = [];
        I_error = [];
        P_error = [];
        for i=1:length(indexDay)
            Y_error = [Y_error; Y_load(Ind(indexDay(i))) - Y_hat(Ind(indexDay(i)))];
            I_error = [I_error; Ind(indexDay(i))];

            if( year(day_index(indexDay(i))) < 2020 )
                P_error = [P_error; ones(24*(nday(n)+1),1)];
            else
                P_error = [P_error; zeros(24*(nday(n)+1),1)];
            end
        end
        X_error = repmat(eye(24*(nday(n)+1)),length(indexDay),1);
        
        % Compute estimator and adjust prediction errors
        bhat = regress(Y_error(P_error==1), X_error(P_error==1,:));
        Y_hat(I_error) = Y_hat(I_error) + X_error * bhat;
    end

end