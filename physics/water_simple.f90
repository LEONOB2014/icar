!>----------------------------------------------------------
!! NOTE: CODE IS INCOMPLETE AND WILL NOT WORK
!!
!! Very simple land surface model code
!! 
!! Rain is partitioned into infiltration and runoff
!! Snow is accumulated on the surface, then melts, runsoff, or sublimates
!! Soil moisture is permitted to be lost to ET or subsurface flow
!! 
!! ET, Sensible Heat Flux, and Longwave are partitioned using Penman Monteith.
!!
!! The entry point to the code is lsm_simple. 
!!
!! <pre>
!! Call tree graph :
!! lsm_simple->
!!  [->],
!!  [->],
!!  [->]
!! 
!! High level routine descriptions / purpose
!!   lsm_simple         - loops over X,Y grid cells, calls a, b, c
!! 
!! Driver inputs: p,th,pii,rho,qv,rain,snow,dt,dz
!!   psfc= surface pressure              - 3D - input  - Pa     - (nx,ny)
!!   t   = temperature                   - 3D - in/out - K      - (nx,nz,ny)
!!   rho = air density                   - 3D - input  - kg/m^3 - (nx,nz,ny)
!!   qv  = specific humidity             - 3D - in/out - kg/kg  - (nx,nz,ny)
!!   wind= wind speed                    - 2D - input  - m/s    - (nx,ny)
!! </pre>
!!
!! Author : Ethan Gutmann (gutmann@ucar.edu)
!!
!!----------------------------------------------------------
module module_water_simple
    use data_structures
    implicit none
    
    real, parameter :: freezing_threshold=273.15
    
contains
    
    real function sat_mr(t,p) 
    ! Calculate the saturated mixing ratio at a temperature (K), pressure (Pa)
        implicit none
        real,intent(in) :: t,p
        real :: e_s,mr_s,a,b

        ! from :
        !     Lowe, P.R. and J.M. Ficke., 1974: THE COMPUTATION OF SATURATION VAPOR PRESSURE 
        !         Environmental Prediction Research Facility, Technical Paper No. 4-74
        !     see: http://www.dtic.mil/dtic/tr/fulltext/u2/778316.pdf
        ! which references:
        !     Murray, F. W., 1967: On the computation of saturation vapor pressure. 
        !         Journal of Applied Meteorology, Vol. 6, pp. 203-204.
        ! Also notes a 6th order polynomial and look up table as viable options. 
        if (t<freezing_threshold) then
            a=21.8745584
            b=7.66
        else
            a=17.2693882
            b=35.86
        endif
        e_s = 610.78* exp(a*(t-273.16)/(t-b)) !(Pa)

        ! alternate formulations
        ! Polynomial:
        ! e_s = ao + t*(a1+t*(a2+t*(a3+t*(a4+t*(a5+a6*t))))) a0-6 defined separately for water and ice
        ! e_s = 611.2*exp(17.67*(t-273.15)/(t-29.65)) ! (Pa)
        ! from : http://www.srh.noaa.gov/images/epz/wxcalc/vaporPressure.pdf
        ! e_s = 611.0*10.0**(7.5*(t-273.15)/(t-35.45))
        
        ! enforce e_s < air pressure incase we are out on one edge of a polynomial
        if ((p-e_s)<=0) then
            e_s=p*0.99999
        endif
        ! e_s=min(e_s,p-SMALL_PRESSURE) ! this is harder to cover a reasonable range of pressure in single precision
        !from : http://www.srh.noaa.gov/images/epz/wxcalc/mixingRatio.pdf
        sat_mr=0.6219907*e_s/(p-e_s) !(kg/kg)
    end function sat_mr
    
    
    subroutine calc_exchange_coefficient(wind,tskin,airt,z_atm,lnz_atm,base_exchange,exchange_C)
        implicit none
        real, intent(in) :: wind,tskin,airt
        real, intent(in) :: z_atm, lnz_atm, base_exchange
        real, intent(out) :: exchange_C
        real :: Ri
        
        Ri = gravity/airt * (airt-tskin)*z_atm/wind**2
        
        if(Ri<0) then
            exchange_C=lnz_atm * (1.0-(15.0*Ri)/(1.0+(base_exchange * sqrt((-1.0)*Ri))))
        else 
            exchange_C=lnz_atm * 1.0/((1.0+15.0*Ri)*sqrt(1.0+5.0*Ri))
        endif
    end subroutine calc_exchange_coefficient
    
    function ocean_roughness(ustar) result(z0)
        implicit none
        real, intent(in) :: ustar
        real :: z0
        
        ! approximately from Beljaars (1995?) in ECMWF model
        z0 = 8e-6 / max(ustar,1e-10)
    end function ocean_roughness
    
    subroutine water_simple(sst, psfc, wind, ustar, qv, temperature,  &
                            sensible_heat, latent_heat, &
                            z_atm, Z0, landmask, &
                            qv_surf, evap_flux, tskin)
        implicit none
        real, dimension(:,:,:),intent(in)    :: qv, temperature, z_atm
        real, dimension(:,:),  intent(inout) :: sensible_heat, latent_heat, Z0, qv_surf, evap_flux, tskin
        real, dimension(:,:),  intent(in)    :: sst, psfc, wind, ustar, landmask
        
        integer :: nx, ny, i, j
        real :: base_exchange_term, lnz_atm_term, exchange_C, z
        
        nx=size(sst,1)
        ny=size(sst,2)
        
        do j=2,ny-1
            do i=2,nx-1
                if (landmask(i,j)==kLC_WATER) then
                    qv_surf(i,j) = 0.98 * sat_mr(sst(i,j),psfc(i,j)) ! multiply by 0.98 to account for salinity
                    
                    Z0(i,j) = ocean_roughness(ustar(i,j))
                    z=z_atm(i,1,j)
                    lnz_atm_term = log((z+Z0(i,j))/Z0(i,j))
                    base_exchange_term=(75*karman**2 * sqrt((z+Z0(i,j))/Z0(i,j))) / (lnz_atm_term**2)
                    lnz_atm_term=(karman/lnz_atm_term)**2
                    
                    call calc_exchange_coefficient(wind(i,j),sst(i,j),temperature(i,1,j),&
                                                   z,lnz_atm_term,base_exchange_term,exchange_C)
                                        
                    sensible_heat(i,j) = exchange_C * wind(i,j) * (sst(i,j)-temperature(i,1,j))
                    evap_flux(i,j)     = exchange_C * wind(i,j) * (qv_surf(i,j)-qv(i,1,j))
                    latent_heat(i,j)   = evap_flux(i,j) * LH_vaporization
                    tskin(i,j)   = sst(i,j)
                    
                endif
            end do
        end do
        
    end subroutine water_simple

end module module_water_simple