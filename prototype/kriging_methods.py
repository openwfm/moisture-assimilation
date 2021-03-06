
from spatial_model_utilities import great_circle_distance
from diagnostics import diagnostics

import numpy as np


def simple_kriging_data_to_model(obs_data, obs_stds, mu_mod, wrf_data, mod_stds, t):
    """
    Simple kriging of data points to model points.  The kriging results in
    the matrix K, which contains the kriged observations and the matrix V,
    which contains the kriging variance.
    """
    mlons, mlats = wrf_data.get_lons(), wrf_data.get_lats()
    K = np.zeros_like(mlons)
    V = np.zeros_like(mlons)
    Nobs = len(obs_data)
    obs_vals = np.zeros((Nobs,))
    station_lonlat = []
    gridndx = []
    mu_obs = np.zeros((Nobs,))
    measV = np.zeros((Nobs,))
        
    # accumulate the indices of the nearest grid points
    ndx = 0
    for obs in obs_data:
        gridndx.append(obs.get_nearest_grid_point())
        obs_vals[ndx] = obs.get_value()
        station_lonlat.append(obs.get_position())
        mu_obs[ndx] = mu_mod[obs.get_nearest_grid_point()]
        measV[ndx] = obs.get_measurement_variance()
        ndx += 1

    # compute observation residuals (using model fit from examine_station_data)
    res_obs = obs_vals - mu_obs
    
    # construct the covariance matrix and invert it
    C = np.asmatrix(construct_spatial_correlation_matrix2(station_lonlat))
    oS = np.asmatrix(np.diag(obs_stds))
    Sigma = oS.T * C * oS + np.diag(measV)
    SigInv = np.linalg.inv(Sigma)
    
    diagnostics().push("skdm_cov_cond", np.linalg.cond(Sigma))
    
    # run the kriging estimator for each model grid point
    K = np.zeros_like(mlats)
    cov = np.zeros_like(mu_obs)
    for p in np.ndindex(K.shape):
        # compute the covariance array anew for each grid point
        for k in range(Nobs):
            lon, lat = station_lonlat[k]
            cc = max(0.8565 - 0.0063 * great_circle_distance(mlons[p], mlats[p], lon, lat), 0.0)
            cov[k] = mod_stds[p] * cc * obs_stds[k]
        csi = np.dot(cov, SigInv)
        K[p] = mu_mod[p] + np.dot(csi, res_obs) 
        V[p] = mod_stds[p]**2 - np.dot(csi, cov)
    
    return K, V


 
def universal_kriging_data_to_model(obs_data, obs_stds, m, wrf_data, mod_stds, t):
    """
    Universal kriging of data points to model points.  The kriging results in
    the matrix K, which contains the kriged observations and the matrix V,
    which contains the kriging variance.
    """
    mlons, mlats = wrf_data.get_lons(), wrf_data.get_lats()
    K = np.zeros_like(mlons)
    V = np.zeros_like(mlons)
    Nobs = len(obs_data)
    obs_vals = np.zeros((Nobs,))
    station_lonlat = []
    gridndx = []
    mu_obs = np.zeros((Nobs,))
    m_pred = np.zeros((Nobs,))
    measV = np.zeros((Nobs,))
        
    # accumulate the indices of the nearest grid points
    ndx = 0
    for obs in obs_data:
        gridndx.append(obs.get_nearest_grid_point())
        obs_vals[ndx] = obs.get_value()
        station_lonlat.append(obs.get_position())
        measV[ndx] = obs.get_measurement_variance()
        m_pred[ndx] = m[obs.get_nearest_grid_point()]
        ndx += 1

    # convert lists to column vectors
    m_pred = np.asmatrix(m_pred).T
    obs_vals = np.asmatrix(obs_vals).T

    # construct the covariance matrix and invert it
    C = np.asmatrix(construct_spatial_correlation_matrix2(station_lonlat))
    oS = np.asmatrix(np.diag(obs_stds))
    Sigma = oS.T * C * oS + np.diag(measV)
    SigInv = np.linalg.inv(Sigma)

    # estimate the fixed part of the model
    gamma = np.linalg.inv(m_pred.T * SigInv * m_pred) * m_pred.T * SigInv * obs_vals
    gamma = gamma[0,0]
    mu_mod = m * gamma

    ndx = 0
    for obs in obs_data:
        mu_obs[ndx] = mu_mod[obs.get_nearest_grid_point()]
        ndx += 1

    # compute observation residuals (using model fit from examine_station_data)
    # and the mean absolute deviation
    res_obs = np.asmatrix(obs_vals - mu_obs).T
    mape = np.mean(np.abs(res_obs))
    
    diagnostics().push("skdm_cov_cond", np.linalg.cond(Sigma))

    # precompute some matrices
    xs = obs_vals.T * SigInv
    xsx_1 = 1.0 / (xs * obs_vals)
    
    # run the kriging estimator for each model grid point
    K = np.zeros_like(mlats)
    cov = np.asmatrix(np.zeros_like(mu_obs)).T
    for p in np.ndindex(K.shape):
        
	# compute the covariance array anew for each grid point
        for k in range(Nobs):
            lon, lat = station_lonlat[k]
            cc = max(0.8565 - 0.0063 * great_circle_distance(mlons[p], mlats[p], lon, lat), 0.0)
            cov[k,0] = mod_stds[p] * cc * obs_stds[k]
        
        csi = SigInv * (cov - obs_vals * xsx_1 * (xs * cov - mu_mod[p]))
        K[p] = csi.T * obs_vals
	tmp = (mu_mod[p] - cov.T * SigInv * obs_vals)
        V[p] = mod_stds[p]**2 - cov.T * SigInv * cov + tmp * xsx_1 * tmp

    return K, V, gamma, mape



def trend_surface_model_kriging(obs_data, wrf_data, mu_mod):
    """
    Trend surface model kriging, which assumes spatially uncorrelated errors.
    The kriging results in the matrix K, which contains the kriged observations
    and the matrix V, which contains the kriging variance.
    """
    Nobs = len(obs_data)
    K = np.zeros_like(mu_mod)
    V = np.zeros_like(mu_mod)
    mu_obs = np.zeros((Nobs,))

    for (obs,i) in zip(obs_data, range(Nobs)):
        mu_obs[i] = mu_mod[obs.get_nearest_grid_point()]

    # FIXME: we assume that the measurement variance is the same for all stations
    sigma2 = obs_data[0].get_measurement_variance()

    # In a TSM, the kriging predictor is the same as the estimator
    K[:] = mu_mod

    # precompute the inverse of the dot product
    XtX_1 = 1.0 / np.sum(mu_obs * mu_obs)

    # We compute the kriging variance for each point (covariates should be used but
    # since mu_mod is a scaled version of the covariates, the result is unchanged)
    for pos in np.ndindex(V.shape):
        V[pos] = sigma2 * (1 + mu_mod[pos] * XtX_1 * mu_mod[pos])
    
    diagnostics().push("skdm_cov_cond", 1.0)

    return K, V
