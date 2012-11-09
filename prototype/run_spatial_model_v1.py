# -*- coding: utf-8 -*-
"""
Created on Sun Oct 28 18:14:36 2012

@author: martin
"""

from spatial_model_utilities import render_spatial_field, great_circle_distance
from time_series_utilities import build_observation_data
                                    
from kriging_methods import simple_kriging_data_to_model
from wrf_model_data import WRFModelData
from cell_model import CellMoistureModel
from mean_field_model import MeanFieldModel
from observation_stations import Station
from diagnostics import init_diagnostics, diagnostics

import matplotlib.pyplot as plt
from mpl_toolkits.basemap import Basemap
import numpy as np
import os
import pytz


station_list = [  "Julian_Moisture",
                  "Goose_Valley_Fuel_Moisture",
                  "Oak_Grove_Moisture",
                  "Decanso_Moisture",
                  "Alpine_Moisture",
                  "Ranchita_Moisture",
                  "Camp_Elliot_Moisture"
                ]

                  
station_data_dir = "../real_data/witch_creek/"

    

class OnlineVarianceEstimator:
    """
    This class keeps an estimate of the running mean and variance of a field.
    Online algorithm taken from wikipedia [attributed to D. Knuth]
    http://en.wikipedia.org/wiki/Algorithms_for_calculating_variance
    """
    
    def __init__(self, imean, ivar, iN):
        """
        Initialize with prior information.  
        """
        self.mean = imean
        self.M2 = ivar
        self.N = iN
        

    def update_with(self, ndata):
        """
        Acquire new sample and update the field statistics.
        """
        self.N += 1
        delta = ndata - self.mean
        self.mean += delta / self.N
        self.M2 += delta * (ndata - self.mean)
         
         
    def get_variance(self):
        """
        Return the current variance estimate.
        """
        return self.M2 / (self.N - 1)
    

    def get_mean(self):
        """
        Returns the estimate of the current mean.
        """
        return self.mean
        


def run_module():
        
    # configure diagnostics        
    init_diagnostics("results/moisture_model_v1_diagnostics.txt")
    diagnostics().configure_tag("skdm_obs_res", True, True, True)
    diagnostics().configure_tag("skdm_obs_res_mean", True, True, True)

    wrf_data = WRFModelData('../real_data/witch_creek/realfire03_d04_20071021.nc')
    
    # read in vars
    lat, lon = wrf_data.get_lats(), wrf_data.get_lons()
    tm = wrf_data.get_times()
    rain = wrf_data['RAINNC']
    Ed, Ew = wrf_data.get_moisture_equilibria()
    
    # obtain sizes
    Nt = rain.shape[0]
    dom_shape = lat.shape
    
    # load station data from files
    tz = pytz.timezone('US/Pacific')
    stations = [Station(os.path.join(station_data_dir, s), tz, wrf_data) for s in station_list]
    for s in stations:
        s.set_measurement_variance('fuel_moisture', 0.1)
    
    # build the observation data structure indexed by time
    obs_data = build_observation_data(stations, 'fuel_moisture', wrf_data)
    
    # construct initial conditions
    E = 0.5 * (Ed[1,:,:] + Ew[1,:,:])
    
    # set up parameters
    Qij = np.eye(9) * 0.0001
    dt = 10.0 * 60
    K = np.zeros_like(E)
    V = np.zeros_like(E)
    mV = np.zeros_like(E)
    Kg = np.zeros_like(E)
    
    # moisture state and observation residual variance estimators
    mod_re = OnlineVarianceEstimator(np.zeros_like(E), np.ones_like(E) * 0.03, 1)
    obs_re = OnlineVarianceEstimator(np.zeros((len(stations),)), np.ones(len(stations),) * 0.1, 1)
    
    # initialize the mean field model (default fit is 1.0 of equilibrium before new information comes in)
    mfm = MeanFieldModel()

    # construct model grid using standard fuel parameters
    Tk = np.array([1.0, 10.0, 100.0]) * 3600
    models = np.zeros(dom_shape, dtype = np.object)
    for pos in np.ndindex(dom_shape): 
        models[pos] = CellMoistureModel((lat[pos], lon[pos]), 3, E[pos], Tk, P0 = Qij)
    
    # construct a basemap representation of the area
    lat_rng = (np.min(lat), np.max(lat))
    lon_rng = (np.min(lon), np.max(lon))
    m = Basemap(llcrnrlon=lon_rng[0],llcrnrlat=lat_rng[0],
                urcrnrlon=lon_rng[1],urcrnrlat=lat_rng[1],
                projection = 'mill')

    plt.figure(figsize = (12, 8))
    
    # run model
    for t in range(1, Nt):
        model_time = wrf_data.get_times()[t]
        print("Time: %s, step: %d" % (str(model_time), t))

        # pre-compute equilibrium moisture to save a lot of time
        E = 0.5 * (Ed[t,:,:] + Ew[t,:,:])
        
        # run the model update
        for pos in np.ndindex(dom_shape):
            i, j = pos
            models[pos].advance_model(Ed[t, i, j], Ew[t, i, j], rain[t, i, j], dt, Qij)
            
        # prepare visualization data        
        f = np.zeros((dom_shape[0], dom_shape[1], 3))
        for p in np.ndindex(dom_shape):
            f[p[0], p[1], :] = models[p].get_state()[:3]
            mV[pos] = models[p].P[1,1]

        # check if we are to update the mean field model first
        if model_time in obs_data:
            mfm.fit_to_data(E, obs_data[model_time])
            obs_vals = np.array([o.get_value() for o in obs_data[model_time]])
            ngp_vals = np.array([E[o.get_nearest_grid_point()] for o in obs_data[model_time]])
            obs_re.update_with(obs_vals - ngp_vals)
            
        Efit = mfm.predict_field(E)
            
        # update the model residual estimator and get current best estimate of variance
        mod_re.update_with(f[:,:,1] - Efit)
        mresV = mod_re.get_variance()

        # if we have an observation somewhere in time
        if model_time in obs_data:
            
            # krige data to observations
            K, V = simple_kriging_data_to_model(obs_data[model_time], obs_re.get_variance() ** 0.5,
                                                Efit, wrf_data, mresV ** 0.5, t)

            # run the kalman update in each model
            # gather the standard deviations of the moisture fuel after the Kalman update
            for pos in np.ndindex(dom_shape):
                Kg[pos] = models[pos].kalman_update(K[pos], V[pos], 1)

        # prepare visualization data        
        f = np.zeros((dom_shape[0], dom_shape[1], 3))
        for p in np.ndindex(dom_shape):
            f[p[0], p[1], :] = models[p].get_state()[:3]
            
        plt.clf()
        plt.subplot(3,3,1)
        render_spatial_field(m, lon, lat, f[:,:,0], 'Fast fuel')
        plt.clim([0.0, 0.2])
        plt.colorbar()
        plt.subplot(3,3,2)
        render_spatial_field(m, lon, lat, f[:,:,1], 'Mid fuel')
        plt.clim([0.0, 0.2])        
        plt.colorbar()
        plt.subplot(3,3,3)
        render_spatial_field(m, lon, lat, f[:,:,2], 'Slow fuel')
        plt.clim([0.0, 0.2])        
        plt.colorbar()
        plt.subplot(3,3,4)
        render_spatial_field(m, lon, lat, Efit, 'Equilibrium Fit')
        plt.clim([0.0, 0.2])        
        plt.colorbar()
        plt.subplot(3,3,5)
        render_spatial_field(m, lon, lat, Kg, 'Kalman gain')       
        plt.clim([0.0, 1.0])        
        plt.colorbar()
        plt.subplot(3,3,6)
        render_spatial_field(m, lon, lat, mV, 'Mid fuel variance')
        plt.clim([0.0, np.max(mV)]) 
        plt.colorbar()
        plt.subplot(3,3,7)
        render_spatial_field(m, lon, lat, K, 'Kriged observations')
        plt.colorbar()
        plt.subplot(3,3,8)
        render_spatial_field(m, lon, lat, V, 'Kriging variance')
        plt.clim([np.min(V), np.max(V)])
        plt.colorbar()
        plt.subplot(3,3,9)
        render_spatial_field(m, lon, lat, mresV, 'Model res. variance')
        plt.clim([0.0, np.max(mresV)])
        plt.colorbar()
        
        plt.savefig('model_outputs/moisture_model_t%03d.png' % t) 
        
                
    
if __name__ == '__main__':
#    profile.run('run_module(); print', 'spatial_model.stats')
#    
#    stats = pstats.Stats('spatial_model.stats')
#    stats.strip_dirs()
#    stats.sort_stats('cumulative')
#    stats.print_stats()

    run_module()