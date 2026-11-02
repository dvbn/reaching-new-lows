function [B_GMM0,COVB0,B_GMM1,COVB1,B_GMM2,COVB2,Jtest,Jpval] = HAC_GMM(YY,XX,ZZ,dof)
w = warning ('off','all');
T = length(YY);

S = eye(size(ZZ,2));
B_GMM0 = (XX'*ZZ*(S\ZZ')*XX)\XX'*ZZ*(S\ZZ')*YY;

U = YY - XX*B_GMM0;
S = cov(ZZ.*repmat(U,1,size(ZZ,2)));
COVB0 = T^(-1)*(XX'*ZZ*(S\ZZ')*XX)\XX'*ZZ*(S\ZZ')*XX/(XX'*ZZ*(S\ZZ')*XX);

B_GMM1 = (XX'*ZZ*(S\ZZ')*XX)\XX'*ZZ*(S\ZZ')*YY;

U = YY - XX*B_GMM1;
S = cov(ZZ.*repmat(U,1,size(ZZ,2)));
COVB1 = T^(-1)*(XX'*ZZ*(S\ZZ')*XX)\XX'*ZZ*(S\ZZ')*XX/(XX'*ZZ*(S\ZZ')*XX);

% %Compute HAC cov matrix.

U = YY - XX*B_GMM1; %errors
% Scores matrix:
V = ZZ.*repmat(U,1,size(ZZ,2)); %element by element multiplication

% Get bandwitdth
options = optimset('fmincon');
options = optimset(options,'display','off','diagnostics','off',...
                           'algorithm','sqp','tolCon',1e-7);
[T,n] = size(V);
maxLag = floor(4*(T/100)^(2/9));
b = maxLag+1;

% Weights (Bartlett)
lags = 0:T-1;
w = zeros(T,1);
x = lags/b;
BT = (abs(x) <= 1);
w(BT) = 1-abs(x(BT));
PhiHat = w(1)*(V'*V); %contemporaneous COV matrix
        for i = 1:min(find(w<1e-6))
            LagCov = (V(1+i:T,:)'*V(1:T-i,:));
            PhiHat = PhiHat+w(i+1)*(LagCov+LagCov');
        end
        
% Compute the sandwich estimate:

% EstCoeffCov = inv(X'*X)*PhiHat*inv(X'*X)  
%             = inv(R'*Q'*Q*R)*Z'*Z*inv(R'*Q'*Q*R)
%             = ((R'*R)\Z')*(Z/(R'*R))
%             = (S\Z')*(Z/S)   

try
Q = chol(PhiHat);    
[~,R] = qr(ZZ,0);
S0 = R'*R;
EstCov = (S0\Q')*(Q/S0);
catch
    [~,R] = qr(ZZ,0);
S0 = R'*R;
EstCov = (S0\PhiHat/S0);
end
S = PhiHat/T;
%se = sqrt(diag(EstCoeffCov)); %standard errors

B_GMM2 = (XX'*ZZ*(S\ZZ')*XX)\XX'*ZZ*(S\ZZ')*YY;


COVB2 = T^(-1)*(XX'*ZZ*(S\ZZ')*XX)\XX'*ZZ*(S\ZZ')*XX/(XX'*ZZ*(S\ZZ')*XX);

g = T^(-1)*ZZ'*(YY-XX*B_GMM2);
Jtest = T*g'*(S\g);
Jpval = 1-chi2cdf(Jtest,dof);


