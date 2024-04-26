! main program
program main
    ! Using the provided modules
    use mpi
    use MOD_INIT
    use forces
    use integrate
    use binning_gestor
    use thermodynamics
    implicit none

    ! MPI variables
    integer :: ierror, rank, nprocs

    ! variable declaration
    integer,parameter :: d=3
    integer :: N,nsim_temp,nsim_tot,numdr,verlet_step
    integer :: M,i,j,k, indx, atoms_per_proc, start_atom, end_atom, n_atoms_remaining
    integer, allocatable :: atoms_list(:), pos_to_transfer(:), displs(:), nlist(:),list(:,:)
    integer :: size_seed, seed
    integer, allocatable :: seed2(:)
    real(8) :: density,L,a,dt,cutoff,temp1,temp2,nu,sigma,temperatura,ke,pot
    real(8) :: timeini,timefin,msdval,r,deltar,volumdr,pi,press
    real(8), allocatable :: pos(:,:), vel(:,:), pos0(:,:), rdf(:),force(:,:), local_rdf(:)
    real(8) , dimension(:), allocatable :: ekin_arr, epot_arr, etot_arr, temp_arr, msd_arr, press_arr
    character(15) :: dummy

    pi=4d0*datan(1d0)
    
    ! ------------------------------------------------------------------ !
    ! Initialize MPI
    call MPI_INIT(ierror)
    call MPI_COMM_RANK(MPI_COMM_WORLD, rank, ierror)
    call MPI_COMM_SIZE(MPI_COMM_WORLD, nprocs, ierror)

    ! Read input parameters (only master)
    if (rank.eq.0) then
        read(*,*) dummy, N
        read(*,*) dummy, nsim_temp
        read(*,*) dummy, nsim_tot
        read(*,*) dummy, verlet_step
        read(*,*) dummy, numdr
        read(*,*) dummy, dt
        read(*,*) dummy, cutoff
        read(*,*) dummy, density
        read(*,*) dummy, temp1
        read(*,*) dummy, temp2
        read(*,*) dummy, nu
        print *, "I am ", rank, "I finished reading inputs. Going to broadcast"
    end if

    ! Broadcast values
    call MPI_BCAST(N, 1, MPI_INTEGER, 0, MPI_COMM_WORLD, ierror)
    call MPI_BCAST(nsim_temp, 1, MPI_INTEGER, 0, MPI_COMM_WORLD, ierror)
    call MPI_BCAST(nsim_tot, 1, MPI_INTEGER, 0, MPI_COMM_WORLD, ierror)
    call MPI_BCAST(verlet_step, 1, MPI_INTEGER, 0, MPI_COMM_WORLD, ierror)
    call MPI_BCAST(numdr, 1, MPI_INTEGER, 0, MPI_COMM_WORLD, ierror)
    call MPI_BCAST(dt, 1, MPI_REAL8, 0, MPI_COMM_WORLD, ierror)
    call MPI_BCAST(cutoff, 1, MPI_REAL8, 0, MPI_COMM_WORLD, ierror)
    call MPI_BCAST(density, 1, MPI_REAL8, 0, MPI_COMM_WORLD, ierror)
    call MPI_BCAST(temp1, 1, MPI_REAL8, 0, MPI_COMM_WORLD, ierror)
    call MPI_BCAST(temp2, 1, MPI_REAL8, 0, MPI_COMM_WORLD, ierror)
    call MPI_BCAST(nu, 1, MPI_REAL8, 0, MPI_COMM_WORLD, ierror)

    ! Allocate variables
    allocate(pos(N,d),force(N,d))
    allocate(vel(N,d))
    allocate(pos0(N,d))
    allocate(rdf(numdr),local_rdf(numdr))
    allocate(pos_to_transfer(nprocs),displs(nprocs)) 
    allocate(nlist(N),list(N,N))
    allocate(ekin_arr(nsim_tot/100), epot_arr(nsim_tot/100), etot_arr(nsim_tot/100), temp_arr(nsim_tot/100), msd_arr(nsim_tot/100), press_arr(nsim_tot/100))

    ! ! Opening files to save results
    ! open(14,file='trajectory.xyz')
    if (rank.eq.0) then
        open(15,file='thermo_kin+pot.dat')
        open(16,file='thermo_tot+msd.dat')
        open(17,file='thermo_temp+press.dat')
        open(18,file='results_rdf.dat')
    endif
    
    !open(20,file='pos.dat')
    !open(21,file='vel.dat')
    !open(22,file='forces.dat')

    call MPI_BARRIER(MPI_COMM_WORLD,ierror) ! Barrier to start program at the same time

    ! Getting the initial time to account for total simulation time
    if (rank.eq.0) then 
        call cpu_time(timeini)
        write(*,*)timeini
    end if

    ! *** DISTRIBUTE ATOMS BETWEEN PROCESSORS *** !
    ! Ensure last proc gets any extra atoms 
    n_atoms_remaining = mod(N, nprocs)
        
    !print*,'check velocity',N,nprocs, n_atoms_remaining
    if (rank < n_atoms_remaining) then
        atoms_per_proc = N / nprocs + 1
        start_atom = rank * atoms_per_proc + 1
        end_atom = start_atom + atoms_per_proc - 1 
    else
        atoms_per_proc = N / nprocs
        start_atom = n_atoms_remaining * (atoms_per_proc + 1) + (rank - n_atoms_remaining) * atoms_per_proc + 1
        end_atom = start_atom + atoms_per_proc - 1
    end if

    ! Save indexes in list
    allocate(atoms_list(atoms_per_proc))
    indx = 1
    do i = start_atom, end_atom
        atoms_list(indx) = i
        indx = indx + 1
    end do

    ! Generate an array with all the number of positions that will be sent later
    call MPI_ALLGATHER(atoms_per_proc,1,MPI_INT,pos_to_transfer,1,MPI_INT,MPI_COMM_WORLD, ierror)

    displs(1) = 0
    do i = 2, nprocs
        displs(i) = displs(i-1)+pos_to_transfer(i-1)
    end do

    !  Initialize random number generator according to system clock (different results each time)  !
    call random_seed(size=size_seed)
    allocate (seed2(size_seed))
    call system_clock(count=seed)
    seed2 = seed
    call random_seed(put=seed2)

    ! *** INITIALIZE SYSTEM *** !
    L=(real(N,8)/density)**(1.d0/3.d0)

    call do_SCC(N, L, pos, atoms_list ,nprocs, rank, "SCCconf_init.xyz",pos_to_transfer,start_atom,end_atom,displs)
    vel=0d0

    ! *** THERMALIZATION *** !
    sigma = sqrt(temp1)
    print*,'Thermalization data'
    call new_vlist(nprocs,N,d,L,pos,list,nlist,cutoff,pos_to_transfer,start_atom,end_atom)
    do i=1,nsim_temp
        if (mod(i,verlet_step).eq.0) then
            call new_vlist(nprocs,N,d,L,pos,list,nlist,cutoff,pos_to_transfer,start_atom,end_atom)
        endif
        call time_step_vVerlet(nprocs,pos,N,d,L,vel,dt,cutoff,nu,sigma,pot,force,pos_to_transfer,start_atom,end_atom,displs,list,nlist)
    enddo  
    print*,'Finished thermalization'

    ! *** PRODUCTION RUN *** !
    sigma=dsqrt(temp2)
    vel=0d0
    pos0=pos
    local_rdf=0d0
    rdf=0d0
    call new_vlist(nprocs,N,d,L,pos,list,nlist,cutoff,pos_to_transfer,start_atom,end_atom)
    do i=1,nsim_tot
        if (mod(i,verlet_step).eq.0) then
            call new_vlist(nprocs,N,d,L,pos,list,nlist,cutoff,pos_to_transfer,start_atom,end_atom)
        endif
        call time_step_vVerlet(nprocs,pos,N,d,L,vel,dt,cutoff,nu,sigma,pot,force,pos_to_transfer,start_atom,end_atom,displs,list,nlist)
        if ((mod(i,1000).eq.0).and.(rank.eq.0)) then
            print*,'timestep',i
        endif
         if (mod(i,100).eq.0) then
            call kin_energy(vel,N,d,start_atom,end_atom,ke)
            call msd(pos,N,d,pos0,L,start_atom,end_atom,msdval)
            call pression(pos,N,d,L,cutoff,start_atom,end_atom,press)
            temperatura=temp_inst(ke,N)
            if (rank.eq.0) then
                write(15,*)i*dt,ke,pot
                write(16,*)i*dt,pot+ke,msdval
                write(17,*)i*dt,temperatura,press+temperatura*density

            ! ! Save results in arrays 
            ! ekin_arr(i/100) = ke
            ! epot_arr(i/100) = pot
            ! etot_arr(i/100) = pot+ke
            ! temp_arr(i/100) = temperatura
            ! msd_arr(i/100) = msdval
            ! press_arr(i/100) = press+temperatura*density

    !         if (mod(i,50000).eq.0) then ! Control state of simulation
    !             print*,i
    !         endif
            endif
        endif
       ! Mesure RDF after a certain timestep
        if (i.gt.1e3) then
            call gr(pos,N,d,numdr,L,start_atom,end_atom,local_rdf)
        endif
  enddo  

    ! 
    ! call binning(ekin_arr, nsim_tot/100, "Ekin_nou.dat")
    call MPI_Allreduce(local_rdf,rdf,numdr,MPI_REAL8,MPI_SUM,MPI_COMM_WORLD,ierror)

    ! ! Normalization of RDF
    if (rank.eq.0) then
        r=0d0
        deltar=0.5d0*L/numdr
        do i=1,numdr
            r=(i-1)*deltar
            volumdr=4d0*pi*((r+deltar/2d0)**3-(r-deltar/2d0)**3)/3d0
            write(18,*)r,rdf(i)/(sum(rdf)*volumdr*density)
        enddo
    endif

    call MPI_BARRIER(MPI_COMM_WORLD,ierror) ! Final barrier to get time

    deallocate(pos_to_transfer,displs)
    deallocate(seed2)

    if (rank.eq.0) then
        call cpu_time(timefin)
        print*,'FINAL time = ',timefin-timeini
    end if
    ! Finalize MPI
    call MPI_FINALIZE(ierror)
    
    end program main
