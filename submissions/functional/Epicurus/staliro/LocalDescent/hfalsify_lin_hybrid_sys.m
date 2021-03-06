function outargv = hfalsify_lin_hybrid_sys(argv)
% Find a descent direction by solving Prob[W].
%
% Interface for this is find_local_min_rob_ell.m.
%
% If testing_type is trajectory or model,
% Prob[W] min       v
%         z=(x,t,v)
%             s.t.  G_E(z) <= v
%                   G_W(z) <= v
%
% If testing_type is trajectory2,
% Prob[W] min       G_W(z)
%         z=(x,t)
%             s.t.  G_E(z) <= 0
%
% INPUTS
%     struct argv with fields in interface, plus:
%     - constr_type  : s_x(t) \in 'guards' or \in 'invariants' of locations
%     - testing_type :  Evaluate constraints, etc, on actual 'trajectory' (as generated by simulator)
%       or 'model' thereof
%     - formulation  : Constraints placed on 'max' over an interval, or at
%       every 'instant' in that interval
%     - use_slack_in_ge  : if 1, the constraint 'x \in E(x_0)' is
%     implemented as G_E(z) <= v. Else, it is implemented as G_E(z) <= 0.
%     (See 7b in paper).
%     - impose_loc_seq   : Sequence of locations we want the system to traverse.
%       This over-rides all other considerations: if this is provided, then
%       we forget about the unsafe set, descent set, the original trajectory,
%       all of it. Just follow this sequence of locations. The last entry
%       is the (fake) descent set.
%
% OUTPUTS
%     See interface.
%
%--------------------------------------------------------------------------
% Input processing
%--------------------------------------------------------------------------
Rcmap = rcmap.instance();
rc = Rcmap.int('RC_SUCCESS');

HA = argv.HA;
h0 = argv.h0; % inital point = [l0, t0, x0]
tt = argv.tt;
constr_type = argv.constr_type;
testing_type = argv.testing_type;
formulation = argv.formulation;
locHis = argv.locHis;
plotit = argv.plotit;
if isfield(argv, 'complete_history')
    complete_history = argv.complete_history;
else
    complete_history = 0;
end
use_slack_in_ge = argv.use_slack_in_ge;
if isfield(argv, 'impose_loc_seq')
    impose_loc_seq = argv.impose_loc_seq;
else
    impose_loc_seq = [];
end
% Iteration index
if isfield(argv, 'it')
    it = argv.it;
else
    it = 1;
end
couleur = argv.couleur;

%--------------------------------------------------------------------------
%% Pre-process data for opt problem
%-------------------------------------------------------------------------
if ~strcmp(testing_type, 'trajectory')
    warning(['[', mfilename, '] hfalsify_lin_hybrid_system tested only with testing type = trajectory!!!'])
end
if strcmp(testing_type, 'model')
    complete_history = 0;
    constr_type = 'guards';
end


n = length(h0(3:end));

l0 = h0(1);
t0 = h0(2);
[ht, rc] = systemsimulator(HA, h0(3:end), [], tt, [], 0);
%hs = [ht.T  ht.LT ht.STraj];
if plotit
    plot(ht.STraj(:,1), ht.STraj(:,2), couleur);
    plot(ht.STraj(1,1), ht.STraj(1,2), 'o');
end
beh = behavior(ht);
index = beh.entry_events(:,1);
tau = beh.entry_events(:,2);

[nearest_point_on_s, tmin, dmin] = DistTrajToUnsafe([ht.T ht.STraj]', HA.unsafe);
if plotit
    plot(nearest_point_on_s(1), nearest_point_on_s(2),'x');
end
disp(['Rob(h0) = ', num2str(dmin)]);


if rc == Rcmap.int('RC_SIMULATION_ZENO')
    disp(['[', mfilename, '] Nominal trajectory is Zeno and can not be used - no optimization']);
    h_sol = h0;
    outargv = struct('rc', Rcmap.int('RC_NO_OPTIMIZATION'), 'h_sol', h_sol, 'tt', tt, 'z_sol', [], 'nboptiter', 0, 'fval', nan);
    return
end

if complete_history
    locHis = ht.lochis;
    complocHis = complete_location_history(locHis, HA);
    if length(complocHis) ~= length(locHis)
        comptt = ceil((1+length(complocHis))*tt/length(locHis)); % tt led us short of locB, so need to extend it
        tt = max(comptt, tt);
    end
    locHis = complocHis;
end

% descent_set = set of points closer to unsafe than f(x0)
descent_set = setenvelope(HA.unsafe, dmin);

%--------------------------------------------------------------------------
%% Compute robustness ellipsoid for HA, centered at h0
%--------------------------------------------------------------------------
Pinv = argv.ell_params{1};
ell_dist = argv.ell_params{3};

%--------------------------------------------------------------------------
%% Set objective and constraint functions for optimization
%--------------------------------------------------------------------------
% TODO: change signature of model_feasability_constr to use commonargs
commonargs = struct('HA', HA, 'location_history', locHis, 'tt', tt, ...
    'descent_set', descent_set, ...
    'constr_type', constr_type, 'formulation', formulation, 'use_slack_in_ge', use_slack_in_ge, ...
    'h0', h0, 'Pinv', Pinv, ...
    'color', couleur);
% the devil is in the details...
if argv.red_hard_limit_on_ellipsoid_nbse
    defaultMFE = argv.one_ellipsoid_max_nbse;
else
    defaultMFE = 800;
end
if isfield(argv,'max_nbse') && ~isinf(argv.max_nbse)
    MaxFunEvals = min([defaultMFE, argv.max_nbse]);
else
    MaxFunEvals = defaultMFE;
end
disp(['MFE = ', num2str(MaxFunEvals),', max_nbse = ',num2str(argv.max_nbse)]);
options = optimset('Algorithm', 'sqp', 'MaxFunEvals', MaxFunEvals, ...
    'Display', 'notify-detailed');
if strcmp(testing_type, 'model')
    nonlcon = @(z)model_feasability_constr(z,HA,n, locHis, tt, descent_set, constr_type, Pinv, h0(3:end)', ix_descent_set);
    F       = @(z)feasability_obj(z, commonargs);
    options = optimset(options, 'GradObj', 'on');
    probType = 'Type-I';
elseif strcmp(testing_type, 'trajectory')
    nonlcon = @(z)presimulated_traj_feasability_constr(z, commonargs);
    F       = @(z)feasability_obj(z, commonargs);
    options = optimset(options, 'GradObj', 'on');
    probType = 'Type-I';
elseif strcmp(testing_type, 'trajectory2')
    nonlcon = @(z)hpresimulated_traj_feasability_constr(z, commonargs);
    F       = @(z)hfeasability_obj(z, commonargs);
    probType = 'Type-II';
end

%--------------------------------------------------------------------------
%% Solving Prob[Wi]
%--------------------------------------------------------------------------
% These two help alleviate the need to simulate the system for every
% iterate, by simulating it only for iterates that differ in the x portion
global prev_z_iterate;
global prev_traj;
% For differentiability, restrict t search space to [t_i,t_{i+1}], which is
% the interval to which tmin belongs, ti = transition time.
[ti, tip1] = find_time_window_for_t(tmin,tau);

if isfield(argv, 'z0')
    z0 = argv.z0;
    prev_z_iterate = nan*ones(size(z0));
    prev_traj = [];
    % upper and lower bounds on x and tau vectors
    lb = [HA.init.cube(:,1); ti;  -inf];
    ub = [HA.init.cube(:,2); tip1; inf];
else
    if strcmp(testing_type, 'trajectory2')
        x0 = h0(3:end)';
        z0 = [x0
            tmin
            ];
        % upper and lower bounds on x and tau vectors
        lb = [HA.init.cube(:,1); ti];
        ub = [HA.init.cube(:,2); tip1];
        prev_z_iterate = nan*ones(size(z0));
    else
        x0 = h0(3:end)';
        v0 = 0;
        z0 = [x0
            tmin
            v0];
        prev_z_iterate = nan*ones(size(z0));
        lb = [HA.init.cube(:,1); ti;  -inf];
        ub = [HA.init.cube(:,2); tip1; inf];
        cin0 = nonlcon(z0);
        assert( isequal(cin0, [-1;0]), ['cin0 not [-1 0] when solving Prob[Wi]!! Rather it is ', num2str(cin0'), '. leh balla??']);
    end
end
fval0 = F(z0);
disp(['fval0 = ',num2str(fval0)])
%lb = [HA.init.cube(:,1); ti;  -inf];
%ub = [HA.init.cube(:,2); tip1; inf];

% Signature: x = fmincon(fun,x0,A,b,Aeq,beq,lb,ub,nonlcon,options)
% z_sol = [xs, ts], with s_{xs}(ts) \in W - not to be confused with the
% initial point of this trajectory = [l0, t0, xs]
[z_sol,fval,exitflag,output] = fmincon(F,z0,[],[],[],[],lb,ub,nonlcon,options);

if exitflag ==-1 || exitflag == -2
    display([probType, '-HFALSIFY: No happy optimization']);
    rc = Rcmap.int('RC_UNHAPPY_OPTIMIZATION');
elseif exitflag == 2
    display([probType, '-HFALSIFY: Change in z too small'])
end
h1 = [l0 t0 z_sol(1:n)'];
nboptiter = output.iterations;
display(['fval = ', num2str(fval), ', exitflag = ', num2str(exitflag)]);
if plotit display(output); end

outargv = struct('h_sol', h1, 'tt', tt, 'z_sol', z_sol, 'nboptiter', nboptiter, 'fval', fval, 'fval0', fval0, 'rc', rc);

end
%===================================================
%% embedded functions
%===================================================
function yes = reached_lu(hs,ix_dmin)
% yes = reached_lu(hs, ix_dmin)
% Returns 1 if trajectory hs is in location of unsafe set at time step
% ix_dmin
h=hs(ix_dmin,1);
yes = HA.unsafe.same_location_as_me(h);
end


function [t1, t2] = find_time_window_for_t(tf, tlist)
% [t1, t2] = find_time_window_for_t(tf,tlist)
% find the time interval [t1, t2] which contains tf, where ti \in vector
% tlist, i=1,2. t2 could be +inf if tf is in the last visited location.
right_on = find (tlist == tf);
if right_on
    t1 = tf; t2 = tf;
else
    [m ix_m] = find(tlist < tf);
    t1 = m(end);
    % If t1 is last in list
    if ix_m(end) == length(ix_m)
        t2 = inf;
    else
        t2 = tlist(ix_m(end)+1);
    end
end
end

