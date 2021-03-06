

%
%  This script runs the extended moisture model for one grid point with the
%  Unscented Kalman Filter.
%

% simulation time in hours (integration step for moisture is 1h)
t = (0:1:150)';
N = length(t);

% parameters of the simulation
T = 300;            % surface temperature, Kelvin
q = 0.005;          % water vapor content (dimensionless)
p = 101325;         % surface pressure, Pascals
% n_k = 2;            % number of fuel categories
% Tk = [10, 100]' * 3600;  % time lags for fuel categories
n_k = 1;            % number of fuel categories
Tk = 10 * 3600;  % time lags for fuel categories
Ndim = 2*n_k + 3;

% construct fuel info
% f_type = [1,2]';
% f_loc = [1, 1]';
f_type = [1]';
f_loc = [1]';
f_info = [ f_type, f_loc ];

% external driving: rainfall characteristics
r = zeros(N,1);
r((t > 5) .* (t < 65) > 0) = 1.1; % 2mm of rainfall form hour 5 to 65

% measured moisture at given times
obs_time = [2, 20, 50, 110, 140]';   % observation time in hours
obs_moisture = [ 0.05; %,  0.045; ...
                 0.3; %, 0.2; ...
                 0.7; %, 0.6; ...
                 0.03; %, 0.04; ...
                 0.032; %, 0.035 ... % measurements for the n_k fuel classes
                 ];

N_obs = length(obs_time);
current_obs = 1;

% initialization of the Kalman filter
m_ext = zeros(Ndim,1);
m_ext(1:n_k) = 0.03;

P = eye(Ndim) * 0.01;   % error covariance of the initial guess

% Kalman filter Q (model error covariance) and R (measurement error covar)
Q = zeros(Ndim);
Q(1:n_k, 1:n_k) = eye(n_k) * 0.001;
R = eye(n_k) * 0.05;

% the observation operator is a n_k x Ndim matrix with I_(n_k) on the left
H = zeros(n_k, Ndim);
H(1:n_k,1:n_k) = eye(n_k);

% storage space for results (with filtering)
m_f = zeros(N, Ndim);
m_f(1, :) = m_ext';

m_n = zeros(N, Ndim); % (without filtering)
m_n(1, :) = m_ext;

% indicator of moisture model that is switched on at each time point
model_ids = zeros(N, n_k);

% storage for matrix traces
trP = zeros(N, 1);
trK = zeros(N, 1);
trS = zeros(N, 1);
sP = zeros(N, Ndim, Ndim);

% W0 is a UKF parameter affecting the sigma point distribution
W0 = 0.0;
Ndim = size(m_ext, 1);
Npts = Ndim * 2 + 1;

% Storage of the sigma points
sigma_pts = zeros(N, Ndim, Npts);

% predict & update loop
for i = 2:N
    
    % compute the integration time step
    dt = (t(i) - t(i-1)) * 3600;
    
    % draw the sigma points
    [m_sigma, w] = ukf_select_sigma_points(m_f(i-1,:)', P, W0);
    sigma_pts(i, :, :) = m_sigma;
    
    % compute & store results for system without Kalman filtering
    m_n(i, :) = moisture_model_ext(T, Tk, q, p, m_n(i-1,:)', f_info, r(i), dt);

    % UKF prediction step - run the sigma set through the nonlinear
    % function
    
    % estimate new moisture mean based on last best guess (m)
    m_sigma_1 = zeros(Ndim, Npts);
    for n=1:Npts-1
        m_sigma_1(:,n) = moisture_model_ext(T, Tk, q, p, m_sigma(:,n), f_info, r(i), dt);
    end
    [m_sigma_1(:,Npts), model_ids(i,:)] = moisture_model_ext(T, Tk, q, p, m_f(i-1,:)', f_info, r(i), dt);
    
    % compute the prediction mean x_mean(i|i-1)
    m_pred = sum(m_sigma_1 * diag(w), 2);
    
    % estimate covariance matrix using the sigma point set
    sqrtP = (m_sigma_1 - repmat(m_pred, 1, Npts)) * diag(sqrt(w));
    P = Q + sqrtP * sqrtP';
    sP(i, :, :) = P;
    trP(i) = abs(prod(eig(P)));
    
    % KALMAN UPDATE STEP (if measurement available) 
    if((current_obs <= N_obs) && (t(i) == obs_time(current_obs)))
        
        % acquire current measurement & move to next one
        y_measured = obs_moisture(current_obs, :)';
        current_obs = current_obs + 1;

        % run the observation model on the sigma point ensemble
        % since the model is linear, I could actuall propagate m_pred
        Y = H * m_sigma_1;
        y_pred = sum(Y * diag(w), 2);
        
        % innovation covariance (H=I due to direct observation)
        sqrtS = (Y - repmat(y_pred, 1, Npts)) * diag(sqrt(w));
        S = sqrtS * sqrtS' + R; 
        trS(i) = prod(eig(S));
        
        % the cross covariance of state & observation errors
        Cxy = (m_sigma_1 - repmat(m_pred, 1, Npts)) * diag(w) * (Y - repmat(y_pred, 1, Npts))';
        
        % Kalman gain is inv(S) * P for this case (direct observation)
        K = Cxy / S;
        %trK(i) = trace(K);
        trK(i) = prod(eig(K(1:n_k,1:n_k)));
        
        % update step of Kalman filter to shift model state
        m_f(i,:) = m_pred + K*(y_measured - y_pred);
        
        % state error covariance is reduced by the observation
        P = P - K*S*K';
    
        % replace the stored covariance by the updated covariance after
        % processing the measurement
        trP(i) = abs(prod(eig(P)));
        
    else
        
        % if no observation is available, store the predicted value
        m_f(i,:) = m_pred;
        
    end
        
end

set(0,'DefaultAxesLooseInset',[0,0,0,0])

figure('units','normalized','outerposition',[0 0 1 1])
subplot(311);
plot(t, m_f(:,1), 'r-', 'linewidth', 2);
hold on;
plot(t, m_n(:,1), 'g-', 'linewidth', 2);
plot(t, r, 'k--', 'linewidth', 2);
plot(obs_time, obs_moisture(:,1), 'ko', 'markersize', 8, 'markerfacecolor', 'm');
plot(repmat(t, 1, 2), [m_f(:,1) - sqrt(sP(:, 1, 1)), m_f(:,1) + sqrt(sP(:, 1, 1))], 'rx');
h = legend('sys + UKF', 'raw', 'orientation', 'horizontal');
set(h, 'fontsize', 10);
title('Plot of the evolution of the moisture model [UKF]', 'fontsize', 12);
ylim([-0.5, 1.2]);

% select time indices corresponding to observation times
[I,J] = ind2sub([N_obs, N], find(repmat(t', N_obs, 1) == repmat(obs_time, 1, N)));
subplot(312);
plot(t, log10(trP), 'b-', 'linewidth', 2);
hold on;
plot(obs_time, log10(trS(J)), 'ko', 'markerfacecolor', 'green', 'markersize', 6);
plot(obs_time, log10(trK(J)), 'ko', 'markerfacecolor', 'red', 'markersize', 6);
hold off;
h = legend('state', 'innov.', 'K', 'orientation', 'horizontal');
set(h, 'fontsize', 10);
title('Kalman filter: log(generalized variance) of covar/Kalman matrices vs. time [UKF]', 'fontsize', 12);
ylim([-12, 5]);

subplot(313);
plot(t, sP(:, 1, 1), 'r-', 'linewidth', 2);
hold on
plot(t, sP(:, 1, 2), 'g-', 'linewidth', 2);
plot(t, sP(:, 1, 3), 'b-', 'linewidth', 2);
plot(t, sP(:, 1, 4), 'k-', 'linewidth', 2);
plot(t, sP(:, 1, 5), 'm-', 'linewidth', 2);
plot(t, sP(:, 2, 2), 'g--', 'linewidth', 2);
plot(t, sP(:, 3, 3), 'b--', 'linewidth', 2);
hold off
h = legend('var(m)', 'cov(m,dT)', 'cov(m,dE)', 'cov(m,dS)', 'cov(m,dTr)', 'orientation', 'horizontal');
set(h, 'fontsize', 8);
title('Covariance between moisture and system parameters [UKF]', 'fontsize', 12);
ylim([-0.005, 0.07]);

print(gcf, '-depsc', 'ukf_assim_ts.eps');

figure('units','normalized','outerposition',[0 0 1 1])
subplot(311);
plot(repmat(t, 1, 2), m_f(:,[2, 5]), 'linewidth', 2);
title('Time constant changes [UKF]', 'fontsize', 12);
h = legend('dTk1', 'dTrk');
set(h, 'fontsize', 10);
ylim([-0.5, 2.5] * 1e-7);

subplot(312);
plot(repmat(t, 1, 2), m_f(:, [3, 4]), 'linewidth', 2);
h = legend('dE', 'dS');
set(h, 'fontsize', 10);
title('Equilibrium changes [UKF]', 'fontsize', 12);
ylim([-15, 5] * 1e-3);

subplot(313);
plot(t, model_ids, 'or', 'markerfacecolor', 'red');
title('Active submodel of the moisture model [UKF]', 'fontsize', 12);
ylim([-1, 5]);

print(gcf, '-depsc', 'ukf_assim_params.eps');
