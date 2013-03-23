module Kriging

#
#  The Kriging module provides two types of service:
#
#  * universal kriging with isotropic covariance or correlation
#  * trend surface model kriging
#
#

using Stations
import Stations.nearest_grid_point, Stations.obs_variance, Stations.obs_value

using Storage
import Storage.spush


function numerical_solve_newton(e2, eps2, k)

    N = size(e2,1)
    s2_eta = 0.0

    val_low = sum(e2 ./ eps2) - (N - k)
    if val < 0.0
        return -1.0
    end

    # Newtons method implementation (initialized with s2_eta = 0)
    while abs(val) > 1e-6
        
        # compute the derivative at the new value
        der = - sum(e2 ./ (eps2 + s2_eta))

        println("numerical_solve: s2_eta $s2_eta val $val der $der")

        # update sigma2_eta estimate
        s2_eta -= val/der

        # compute the new value of the function given current value
        val = sum(e2 ./ (eps2 + s2_eta)) - (N - k)

    end

    return s2_eta

end

    
function numerical_solve_bisect(e2, eps2, k)

    N = size(e2,1)
    tgt = N - k
    s2_eta_left = 0.0
    s2_eta_right = 0.1

    val_left = sum(e2 ./ eps2)
    val_right = sum(e2 ./ (eps2 + s2_eta_right))
    if val_left < tgt
        return -1.0
    end

    while val_right > tgt
        s2_eta_right *= 2.0
        val_right = sum(e2 ./ (eps2 + s2_eta_right))
    end

    # Newtons method implementation (initialized with s2_eta = 0)
    while val_left - val_right > 1e-6
        
        # compute new value at center of eta interval
        s2_eta = 0.5 * (s2_eta_left + s2_eta_right)
        val = sum(e2 ./ (eps2 + s2_eta))

        if val > tgt
            val_left, s2_eta_left = val, s2_eta
        else
            val_right, s2_eta_right = val, s2_eta
        end

    end

    return 0.5 * (s2_eta_left + s2_eta_right)

end


function trend_surface_model_kriging(obs_data, X, K, V)
    """
    Trend surface model kriging, which assumes spatially uncorrelated errors.

    WARNING: The variable X is clobbered.

    The kriging results in the matrix K, which contains the kriged observations
    and the matrix V, which contains the kriging variance.
    """
    Nobs = length(obs_data)
    Ncov_all = size(X,3)

    dsize = size(X)[1:2]
    y = zeros((Nobs,1))
    m_var = zeros(Nobs)

    # quick pre-conditioning hack
    # rescale all X[:,:,i] to have norm of X[:,:,1]
    norm_1 = sum(X[:,:,1].^2)^0.5
    for i in 2:Ncov_all
        norm_i = sum(X[:,:,i].^2)^0.5
        if norm_i > 0.0
            X[:,:,i] *= norm_1 / norm_i
        end
    end

    Xobs = zeros(Nobs, Ncov_all)
    for (obs,i) in zip(obs_data, 1:Nobs)
    	p = nearest_grid_point(obs)
        y[i] = obs_value(obs)
        Xobs[i,:] = X[p[1], p[2], :]
        m_var[i] = obs_variance(obs)
    end

    # if we have zero covariates, we must exclude them or a singular exception will be thrown by \
    cov_ids = (1:Ncov_all)[find(map(i -> sum(Xobs[:,i].^2) > 0, 1:Ncov_all))]
    Ncov = length(cov_ids)
    X = X[:,:,cov_ids]
    Xobs = Xobs[:, cov_ids]

    # initialize iterative algorithm
    s2_eta_hat_old = -10.0
    s2_eta_hat = 0.0
    XtSX = nothing
    beta = nothing

    i = 0
    subzeros = 0
    while abs( (s2_eta_hat_old - s2_eta_hat) / max(s2_eta_hat_old, s2_eta_hat)) > 1e-2
    
        # shift current estimate to old var
        s2_eta_hat_old = s2_eta_hat

        # recompute the covariance matrix
        Sigma = diagm(m_var) + s2_eta_hat * eye(Nobs)
        XtSX = Xobs' * (Sigma \ Xobs)
        beta = XtSX \ Xobs' * (Sigma \ y)
        res = y - Xobs * beta

        # compute new estimate of variance of microscale variability
        s2_array = res.^2 - m_var
        for j in 1:Nobs
            s2_array[j] += dot(vec(Xobs[j,:]), vec(XtSX \ Xobs[j,:]'))
        end
        s2_eta_hat2 = sum(s2_array) / Nobs

        s2_eta_hat = numerical_solve_bisect(res.^2, m_var, Ncov)

        subzeros = sum(s2_array .< 0)
        i += 1
        println("Iter: $i  old $s2_eta_hat_old  new $s2_eta_hat  other $s2_eta_hat2")
    end

    # compute the OLS fit of the covariates to the observations
    spush("kriging_xtx_cond", cond(XtSX))
    spush("kriging_errors", (Xobs * beta - y)')

    # printing construction that makes sure order of printed betas does not vary
    # across times even if there are zero covariates
    beta_ext = ones((Ncov_all,1)) * NaN
    beta_ext[cov_ids] = beta
    spush("kriging_beta", beta_ext)

    spush("kriging_sigma2_eta", s2_eta_hat)
    spush("kriging_iters", i)
    spush("kriging_subzero_s2_estimates", subzeros)

    # compute kriging field and kriging variance 
    for i in 1:dsize[1]
        for j in 1:dsize[2]
            x_ij = squeeze(X[i,j,:], 1)'   # convert covariates at position i,j into a column vector
            K[i,j] = dot(vec(x_ij), vec(beta))
            V[i,j] = s2_eta_hat + dot(vec(x_ij), vec(XtSX \ x_ij))
        end
    end

end


end