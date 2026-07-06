//
//  main.mm
//
//
//  Created by SC Lee on 12/09/13.
//  Copyright (c) 2017 SC Lee . All rights reserved.
//
//
//  MSR Kext Access modifiyed from AnVMSR by  Andy Vandijck Copyright (C) 2013 AnV Software
//
//   This is licensed under the
//      GNU General Public License v3.0
//
//
//

#import <Foundation/Foundation.h>
#import <sstream>
#include "TargetConditionals.h"
#include <mach-o/dyld.h>
#include <libgen.h>
#include <sys/syslimits.h>

#define kAnVMSRClassName "VoltageShiftAnVMSR"

io_connect_t connect ;

io_service_t service ;


enum {
    AnVMSRActionMethodRDMSR = 0,
    AnVMSRActionMethodWRMSR = 1,
    AnVMSRNumMethods
};

typedef struct {
	UInt32 action;
    UInt32 msr;
    UInt64 param;
} inout;

io_service_t getService() {
	io_service_t service = 0;
	mach_port_t masterPort;
	io_iterator_t iter;
	kern_return_t ret;
	io_string_t path;
	
	ret = IOMasterPort(MACH_PORT_NULL, &masterPort);
	if (ret != KERN_SUCCESS) {
		printf("Can't get masterport\n");
		goto failure;
	}
	
	ret = IOServiceGetMatchingServices(masterPort, IOServiceMatching(kAnVMSRClassName), &iter);
	if (ret != KERN_SUCCESS) {
		printf("VoltageShift.kext is not running\n");
		goto failure;
	}
	
	service = IOIteratorNext(iter);
	IOObjectRelease(iter);
	
	ret = IORegistryEntryGetPath(service, kIOServicePlane, path);
	if (ret != KERN_SUCCESS) {
		// printf("Can't get registry-entry path\n");
		goto failure;
	}
	
failure:
	return service;
}

void usage(const char *name)
{
    
    printf("--------------------------------------------------------------------------\n");
    printf("VoltageShift Tool v 1.25 for Intel Haswell+ \n");
    printf("Copyright (C) 2020 SC Lee \n");
    printf("--------------------------------------------------------------------------\n");

    printf("Usage:\n");
    printf("set Power Limit: %s power <PL1> <PL2>\n\n", name);
    printf("set Turbo Enabled: %s turbo <0/1>\n\n", name);
    printf("read MSR: %s read <HEX_MSR>\n\n", name);
    printf("write MSR: %s write <HEX_MSR> <HEX_VALUE>\n\n", name);
}

unsigned long long hex2int(const char *s)
{
    return strtoull(s,NULL,16);
}

void printBits(size_t const size, void const * const ptr)
{
    unsigned char *b = (unsigned char*) ptr;
    unsigned char byte;
    int i, j;
     printf("(");
    
    for (i=size-1;i>=0;i--)
    {
        
        for (j=7;j>=0;j--)
        {
            byte = (b[i] >> j) & 1;
            printf("%u", byte);
        }
        if (i!=0)
            printf(" ");
        else
        puts(")");
    }
   // puts(" )");
}



int setPower(int argc,int p1,int p2){
    
               inout in;
               inout out;
               size_t outsize = sizeof(out);
               
               kern_return_t ret;
               
               in.action = AnVMSRActionMethodRDMSR;
               in.param = 0;
               
               double p1power =0;
               double p2power =0;
      
               if (p1power==0){
                   in.msr = 0x610;
                   ret = IOConnectCallStructMethod(connect,
                                                   AnVMSRActionMethodRDMSR,
                                                   &in,
                                                   sizeof(in),
                                                   &out,
                                                   &outsize
                                                   );
                   
                   if (ret != KERN_SUCCESS)
                   {
                       printf("Can't read  0x610 ");
                       
                       return (1);
                       
                   }
                   p1power = (double)(out.param & 0x7FFF ) / 8;
                   
                   p2power = (double)(out.param >> 32 & 0x7FFF ) / 8;
                   
               }
               
               printf("Current Setting: PL1(Long term): %.fW, PL2(Short term) %.fW\n",p1power,p2power);
               
               if (argc <=3){
                
                   return (1);
               }
               
                if (p1==-1 || p2==-1){
                  
                    return (1);
                }
    
               if (p1<5*8 || p2<5*8){
                   printf("your setting may too low, at least 5W \n");
                   return (1);
               }
                   
               for(int i=0;i<15;i++){
                   out.param ^= (-(p1>>i &0x1) ^ out.param) & (1UL << i);
               }
               
               for(int i=32;i<47;i++){
                   out.param ^= (-(p2>>i &0x1) ^ out.param) & (1UL << i);
               }
               
               in.action = AnVMSRActionMethodWRMSR;
               in.param = out.param;
               
               ret = IOConnectCallStructMethod(connect,
                                               AnVMSRActionMethodWRMSR,
                                               &in,
                                               sizeof(in),
                                               &out,
                                               &outsize
                                               );
               
               if (ret != KERN_SUCCESS)
               {
                   printf("Can't connect to StructMethod to send commands\n");
               }else{
               printf("Modified Setting: PL1(Long term): %dW, PL2(Short term) %dW\n",p1/8,p2/8);
               }
    
    return 1;
}

int setPower(int argc,const char * argv[]){

    int p1 = 0;
    int p2 = 0;
    if (argc <=3 ){
        printf(" %s power <PL1> <PL2> \n",argv[0]);
        printf("PL1 - long term power limited\n");
        printf("PL2 - short term power limited\n");
        printf("------------------------------------------------------\n");
    }else{
    
    p1 = (int)strtol((char *)argv[2],NULL,10) *8;
    p2 = (int)strtol((char *)argv[3],NULL,10) *8;
    }
    return setPower(argc,p1,p2);
    
}

int setTurbo(int argc,bool enable){
    
    inout in;
    inout out;
    size_t outsize = sizeof(out);
    
    in.action = AnVMSRActionMethodRDMSR;
    in.param = 0;
    bool turbodisabled = false;
    kern_return_t ret;
    
    if (turbodisabled==false){
        in.msr = 0x1a0;
        ret = IOConnectCallStructMethod(connect,
                                        AnVMSRActionMethodRDMSR,
                                        &in,
                                        sizeof(in),
                                        &out,
                                        &outsize
                                        );
        
        if (ret != KERN_SUCCESS)
        {
            printf("Can't read  0x1a0 ");
            
            return (1);
            
        }
        turbodisabled = (out.param >> 38 & 0x1)>0?true:false;
        
    }
    
    printf("Current Setting: Turbo Boost **%s\n",turbodisabled?"Disabled":"Enabled");
    
    if (argc <=2 ){

        return (0);
        
    }
    
    if (enable)
        turbodisabled = 0;
    else
        turbodisabled = 1;

    // Force bit 38 of out.param to match the desired state.
    if (turbodisabled)
        out.param |= ((uint64)1 << 38);
    else
        out.param &= ~((uint64)1 << 38);
    
    in.action = AnVMSRActionMethodWRMSR;
    in.param = out.param;
    
    ret = IOConnectCallStructMethod(connect,
                                    AnVMSRActionMethodWRMSR,
                                    &in,
                                    sizeof(in),
                                    &out,
                                    &outsize
                                    );
    
    if (ret != KERN_SUCCESS)
    {
        printf("Can't connect to StructMethod to send commands\n");
    }else{
       printf("Modified Setting: Turbo Boost **%s\n",turbodisabled?"Disabled":"Enabled");
    }
    
    return 1;
    
}

int setTurbo(int argc,const char * argv[]){
    
    bool enable = true;
    
    if (argc <=2 ){
        printf("------------------------------------------------------\n");
      printf(" %s turbo 0 \n",argv[0]);
         printf(" for disable Intel turbo \n\n");
      printf(" %s turbo 1 \n",argv[0]);
         printf(" for enable Intel turbo \n");
      printf("------------------------------------------------------\n");
        
    }else{
        
        enable = (int)strtol((char *)argv[2],NULL,10)==1;
        
    }
    return setTurbo(argc,enable);

}

void unloadkext() {

    if(connect)
    {
       kern_return_t ret = IOServiceClose(connect);
        if (ret != KERN_SUCCESS)
        {

        }
    }

    if(service)
        IOObjectRelease(service);

    std::stringstream output;
    output << "sudo kextunload -q -b "
      << "com.sicreative.VoltageShift"
    << " " ;

    system(output.str().c_str());

}

// Resolve the absolute directory containing this Mach-O binary.
// Uses the kernel-reported executable path (independent of pwd or argv[0]).
static std::string kextDirectory() {
    char path[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) {
        return ".";
    }
    char resolved[PATH_MAX];
    if (realpath(path, resolved) == NULL) {
        return ".";
    }
    char *dir = dirname(resolved);
    return std::string(dir);
}

void loadkext() {
    auto dir = kextDirectory();
    std::string kextPath = dir + "/VoltageShift.kext";

    std::stringstream output;
    output << "sudo kextutil -q -r \"" << dir << "\" -b "
           << "com.sicreative.VoltageShift"
           << " ";
    int ret = system(output.str().c_str());

    if (ret != 0) {
        std::stringstream fix;
        fix << "sudo chown -R root:wheel \"" << kextPath << "\" && "
            << "sudo chmod -R 755 \"" << kextPath << "\"";
        system(fix.str().c_str());
        system(output.str().c_str());
    }
}

int main(int argc, const char * argv[])
{
    
#if TARGET_CPU_ARM64
    
    printf("\n\n\n\n\n");
    printf("--------------------------------------------------------------------------\n");
    printf("VoltageShift Don't support ARM (Apple Silicon)\n");
    printf("--------------------------------------------------------------------------\n");
    
    return(1);
    
#endif
    
    char * parameter;
    char * msr;
    char * regvalue;
    service = getService();
    
    if (argc >= 2)
    {
        parameter = (char *)argv[1];
        
    } else {
        usage(argv[0]);
        
        return(1);
    }
    
    int count = 0;
    while (!service && strncmp(parameter, "loadkext", 8) && strncmp(parameter, "unloadkext", 10) ){
        
        service = getService();
        
        if (!service)
            loadkext();

        count++;
        
        // Try load 10 times, otherwise error return
        if (count > 10)
            return (1);
    }
		
	kern_return_t ret;
	//io_connect_t connect = 0;
	ret = IOServiceOpen(service, mach_task_self(), 0, &connect);
	if (ret != KERN_SUCCESS)
    {
        printf("Couldn't open IO Service\n");
    }

    if (argc >= 3)
    {
        msr = (char *)argv[2];
    }
    
    if (!strncmp(parameter, "unloadkext", 10)){
            unloadkext();

        }else if (!strncmp(parameter, "loadkext", 8)){
            loadkext();
            return 0;

        } else if (!strncmp(parameter, "turbo", 5)){

            setTurbo(argc,argv);

        } else if (!strncmp(parameter, "power", 5)){

            setPower(argc,argv);

        }
    else if (!strncmp(parameter, "read", 4))
    {
        
        inout in;
        inout out;
        size_t outsize = sizeof(out);
        
        in.msr = (UInt32)hex2int(msr);
        in.action = AnVMSRActionMethodRDMSR;
        in.param = 0;

#if MAC_OS_X_VERSION_MIN_REQUIRED <= MAC_OS_X_VERSION_10_4
        ret = IOConnectMethodStructureIStructureO( connect, AnVMSRActionMethodRDMSR,
											  sizeof(in),			/* structureInputSize */
											  &outsize,    /* structureOutputSize */
											  &in,        /* inputStructure */
											  &out);       /* ouputStructure */
#else
        ret = IOConnectCallStructMethod(connect,
									AnVMSRActionMethodRDMSR,
									&in,
									sizeof(in),
									&out,
									&outsize
									);
#endif

        if (ret != KERN_SUCCESS)
        {
            printf("Can't connect to StructMethod to send commands\n");
        }

       // printf("RDMSR %x returns value 0x%llx\n", (unsigned int)in.msr, (unsigned long long)out.param);
                printBits(sizeof(out.param), &out.param);
        
    } else if (!strncmp(parameter, "write", 5)) {
        if (argc < 4)
        {
            usage(argv[0]);
            
            return(1);
        }
        
        inout in;
        inout out;
        size_t outsize = sizeof(out);

        regvalue = (char *)argv[3];

        in.msr = (UInt32)hex2int(msr);
        in.action = AnVMSRActionMethodWRMSR;
        in.param = hex2int(regvalue);

       // printf("WRMSR %x with value 0x%llx\n", (unsigned int)in.msr, (unsigned long long)in.param);
        
        ret = IOConnectCallStructMethod(connect,
                                        AnVMSRActionMethodWRMSR,
                                        &in,
                                        sizeof(in),
                                        &out,
                                        &outsize
                                        );
       
        if (ret != KERN_SUCCESS)
        {
            printf("Can't connect to StructMethod to send commands\n");
        }
    } else {
        usage(argv[0]);

        return(1);
    }

        if(connect)
        {
            ret = IOServiceClose(connect);
            if (ret != KERN_SUCCESS)
            {
              //  printf("IOServiceClose failed\n");
            }
        }
        
        if(service)
            IOObjectRelease(service);
    
        unloadkext();

    return 0;
}
           
