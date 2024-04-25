! main program
program main
    ! Using the provided modules
    use mpi

    use MOD_INIT
    use integrate
    use binning_gestor
    ! use [integration]
    ! use [force]
    use thermodynamics
    implicit none
    ! MPI variables
    integer :: ierror, rank, nprocs

    ! variable declaration
    integer,parameter :: d=3
    integer :: N,nsim_temp,nsim_tot,numdr
    integer :: M,i,j,k, indx, atoms_per_proc, start_atom, end_atom, n_atoms_remaining
    integer, allocatable :: atoms_list(:), pos_to_transfer(:), displs(:)
    real(8) :: density,L,a,dt,cutoff,temp1,temp2,nu,sigma,temperatura,ke,pot
    real(8) :: timeini,timefin,msdval,r,deltar,volumdr,pi,press
    real(8), allocatable :: pos(:,:), vel(:,:), pos0(:,:), rdf(:),force(:,:)
    real(8) , dimension(:) :: ekin_arr, epot_arr, etot_arr, temp_arr, msd_arr, press_arr
    character(15) :: dummy

    pi=4d0*datan(1d0)
    
    ! ------------------------------------------------------------------ !
    ! Initialize MPI
    call MPI_INIT(ierror)
    call MPI_COMM_RANK(MPI_COMM_WORLD, rank, ierror)
    call MPI_COMM_SIZE(MPI_COMM_WORLD, nprocs, ierror)



   ! allocate(pos_to_transfer(nprocs),displs(nprocs)) 

    print *, "Hi! I am", rank
    if (rank.eq.0) then
        ! Read parameters (only master)
        read(*,*) dummy, N
        read(*,*) dummy, nsim_temp
        read(*,*) dummy, nsim_tot
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
    allocate(rdf(numdr))

    ! ! Opening files to save results
    ! open(14,file='trajectory.xyz')
    ! open(15,file='thermodynamics.dat')
    ! open(16,file='resultsrdflong_def.dat')
    

    !open(20,file='pos.dat')
    !open(21,file='vel.dat')
    !open(22,file='forces.dat')

    call MPI_BARRIER(MPI_COMM_WORLD,ierror) ! Barrier to start program at the same time

    ! Getting the initial time to account for total simulation time
    if (rank.eq.0) then 
        call cpu_time(timeini)
        write(*,*)timeini
    end if

    allocate(pos_to_transfer(nprocs),displs(nprocs)) 
    
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

    !print *, "Rank-start-app-end", start_atom,atoms_per_proc,end_atom

    ! Save indexes in list
    allocate(atoms_list(atoms_per_proc))
    indx = 1
    do i = start_atom, end_atom
        atoms_list(indx) = i
        indx = indx + 1
    end do
    !print*,'beforeallgather'

    ! Generate an array with all the number of positions that will be sent later
    call MPI_ALLGATHER(atoms_per_proc,1,MPI_INT,pos_to_transfer,1,MPI_INT,MPI_COMM_WORLD, ierror)
    !print*,'ididalgather'
    ! Calculate displs

    displs(1) = 0
    do i = 2, nprocs
        displs(i) = displs(i-1)+pos_to_transfer(i-1)
    end do
    !print*,'thisisdisps'
    !print *, "I", rank, "have",pos_to_transfer, displs

    call srand(1)

    ! Initialize system
    L=(real(N,8)/density)**(1.d0/3.d0)
    call do_SCC(N, L, pos, atoms_list ,nprocs, rank, "SCCconf_init.xyz")
    !print*,'i',rank,'finished init'
    ! call MPI_BARRIER(MPI_COMM_WORLD,ierror)
    ! if (rank.eq.0) then 
    !     print *, rank
    !     print *, atoms_list
    ! end if 

    ! call MPI_BARRIER(MPI_COMM_WORLD,ierror)
    ! if (rank.eq.1) then 
    !     print *, rank
    !     print *, atoms_list
    ! end if 

    ! HERE GOES SEPARATION OF PARTICLES BY PROC
    vel=0d0
    !Thermalization
    sigma = sqrt(temp1)
    print*,'thermalization data'
    do i=1,nsim_temp
         !print*,'enteredverlet'
         call time_step_vVerlet(nprocs,pos,N,d,L,vel,dt,cutoff,nu,sigma,pot,force,pos_to_transfer,start_atom,end_atom,displs)
         if ((mod(i,100).eq.0).and.(rank.eq.0)) then
            call kin_energy(vel,N,d,ke)
            temperatura=temp_inst(ke,N)
           print*,'timestep',i,pot,ke,pot+ke,temperatura
    !       do j=1,N
    !            write(20,*)i,j,pos(j,:)
    !            write(21,*)i,j,vel(j,:)
    !            write(22,*)i,j,force(j,:)
    !       enddo
        endif
!if ((mod(i,10).eq.0).and.(rank.eq.0)) then
            !print*,'timestep',i,pot
         !endif
    enddo  

    print*,'Acabat termalitzacio'
    sigma=dsqrt(temp2)
    vel=0d0
    do i=1,nsim_tot
        call time_step_vVerlet(nprocs,pos,N,d,L,vel,dt,cutoff,nu,sigma,pot,force,pos_to_transfer,start_atom,end_atom,displs)
         if ((mod(i,100).eq.0).and.(rank.eq.0)) then
            call kin_energy(vel,N,d,ke)
            temperatura=temp_inst(ke,N)
           print*,'timestep',i,pot,ke,pot+ke,temperatura
    !       do j=1,N
    !            write(20,*)i,j,pos(j,:)
    !            write(21,*)i,j,vel(j,:)
    !            write(22,*)i,j,force(j,:)
    !       enddo
        endif
  enddo  

    ! !Starting production run
    ! sigma=sqrt(temp2)
    ! pos0=pos
    ! rdf=0d0
    
    ! do i=1,nsim_tot
    !     call time_step_vVerlet(pos,N,d,L,vel,dt,cutoff,nu,sigma,pot)
    !     if (mod(i,100).eq.0) then
    !         ! Mesure energy, pressure and msd
    !         call kin_energy(vel,N,d,ke)
    !         call msd(pos,N,d,pos0,L,msdval)
    !         call pression(pos,N,d,L,cutoff,press)
    !         temperatura=temp_inst(ke,N)
    !         write(15,*)i*dt,ke,pot,pot+ke,temperatura,msdval,press+temperatura*density

    !         if (mod(i,50000).eq.0) then ! Control state of simulation
    !             print*,i
    !         endif

             ! Save results in arrays 
             ekin_arr(i/100) = ke
             epot_arr(i/100) = pot
             etot_arr(i/100) = pot+ke
             temp_arr(i/100) = temperatura
             msd_arr(i/100) = msdval
             press_arr(i/100) = press+temperatura*density

    !         ! Mesure RDF after a certain timestep
    !         if (i.gt.1e3) then
                 ! Binning mesures
                  call binning(ekin_arr, i/100, Epot_nou.f90)
    !             call gr(pos,N,d,numdr,L,rdf)
    !         endif
    !     endif
    !     AQUI PRBLY TOCA POSAR UNA BARRERA
    ! enddo
    
    ! ! Normalization of RDF
    ! r=0d0
    ! deltar=0.5d0*L/numdr
    ! do i=1,numdr
    !     r=(i-1)*deltar
    !     volumdr=4d0*pi*((r+deltar/2d0)**3-(r-deltar/2d0)**3)/3d0
    !     write(16,*)r,rdf(i)/(sum(rdf)*volumdr*density)
    ! enddo

    call MPI_BARRIER(MPI_COMM_WORLD,ierror) ! Final barrier to get time

    deallocate(pos_to_transfer,displs)

    if (rank.eq.0) then
        call cpu_time(timefin)
        print*,'FINAL time = ',timefin-timeini
    end if
    ! Finalize MPI
    call MPI_FINALIZE(ierror)
    
    end program main
