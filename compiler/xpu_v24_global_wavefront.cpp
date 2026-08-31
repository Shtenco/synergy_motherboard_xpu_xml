#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <limits>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>
using namespace std;

struct Fabric {
    int chiplets=4, clusters_per_chiplet=24, tiles_per_cluster=16, lanes_per_tile=8;
    int ingress_ports=24, banks=32, radix_planes=8, package_words_per_output=256;
    double hz=1.2e9;
    int tiles_per_chiplet() const { return clusters_per_chiplet*tiles_per_cluster; }
    int tiles() const { return chiplets*tiles_per_chiplet(); }
    int lanes() const { return tiles()*lanes_per_tile; }
} F;

struct Parents { int32_t a=-1,b=-1; };
struct L {int c,cl,t;};
static inline L loc(int tile){ int c=tile/F.tiles_per_chiplet(); int q=tile%F.tiles_per_chiplet(); return {c,q/16,q%16}; }
static inline int hcost(int a,int b){ if(a==b)return 0; auto A=loc(a),B=loc(b); if(A.c==B.c&&A.cl==B.cl)return 1; if(A.c==B.c)return 4; return 12; }

static int G_ROOTS=98304; static bool G_EXPRESS=true;
static vector<Parents> gen_locality_profile(int n, string kind){
    const int roots=G_ROOTS;
    vector<Parents> P(n);
    if(kind=="reduction_tree"){
        int r=(n+1)/2; int nxt=r; vector<int> prev(r); for(int i=0;i<r;i++) prev[i]=i;
        while(prev.size()>1 && nxt<n){ vector<int> cur; cur.reserve((prev.size()+1)/2); for(size_t i=0;i<prev.size()&&nxt<n;i+=2){P[nxt].a=prev[i]; if(i+1<prev.size())P[nxt].b=prev[i+1]; cur.push_back(nxt++);} prev.swap(cur);} return P;
    }
    for(int v=roots;v<n;v++){
        int c=v%roots; int layer=v/roots; int prev=(layer-1)*roots;
        int tile=c%1536; int lanegrp=c/1536;
        P[v].a=prev+c;
        int other=c;
        uint32_t h=(uint32_t)c*2654435761u + (uint32_t)layer*2246822519u;
        if(kind=="all_local"){
            int k=(lanegrp+1)&15; other=tile+k*1536;
        } else if(kind=="target_80_15_3_2"){
            int bucket=h%100;
            if(bucket<60){ int k=(lanegrp+1+(h>>8)%15)&15; other=tile+k*1536; }
            else if(bucket<90){ auto x=loc(tile); int t2=x.c*384+x.cl*16+((x.t+1+(h>>8)%15)&15); other=t2+lanegrp*1536; }
            else if(bucket<96){ auto x=loc(tile); int cl2=(x.cl+1+(h>>8)%23)%24; int t2=x.c*384+cl2*16+x.t; other=t2+lanegrp*1536; }
            else { int t2=(tile+384*(1+(h>>8)%3))%1536; other=t2+lanegrp*1536; }
        } else if(kind=="cluster_heavy"){
            auto x=loc(tile); int t2=x.c*384+x.cl*16+((x.t+1+(h>>8)%15)&15); other=t2+lanegrp*1536;
        } else if(kind=="global_shuffle"){
            int t2=(tile + 384*(1+(h>>8)%3) + ((h>>16)%384))%1536; other=t2+lanegrp*1536;
        }
        other%=roots; P[v].b=prev+other;
        if(P[v].b==P[v].a) P[v].b=-1;
    }
    return P;
}

struct RStage{uint32_t id; uint16_t cap;};
static vector<RStage> path_for(int src,int dst){
    if(src==dst)return {};
    auto s=loc(src),d=loc(dst); vector<RStage> v; uint16_t ccl=16*F.radix_planes, cch=64*F.radix_planes;
    auto rid=[](int ns,int a,int b,int st){return (uint32_t)((ns<<28)|(a<<20)|(b<<8)|st);};
    if(G_EXPRESS){
        if(s.c==d.c&&s.cl==d.cl){v.push_back({rid(1,s.c,s.cl,0),ccl});return v;}
        if(s.c==d.c){v.push_back({rid(2,s.c,s.cl,0),ccl});v.push_back({rid(3,s.c,0,0),cch});v.push_back({rid(6,d.c,d.cl,0),ccl});return v;}
        v.push_back({rid(2,s.c,s.cl,0),ccl});v.push_back({rid(3,s.c,0,0),cch});v.push_back({rid(4,d.c,0,0),(uint16_t)F.package_words_per_output});v.push_back({rid(5,d.c,0,0),cch});v.push_back({rid(6,d.c,d.cl,0),ccl});return v;
    }
    if(s.c==d.c&&s.cl==d.cl){v.push_back({rid(1,s.c,s.cl,0),ccl});v.push_back({rid(1,s.c,s.cl,1),ccl});return v;}
    v.push_back({rid(2,s.c,s.cl,0),ccl});v.push_back({rid(2,s.c,s.cl,1),ccl});
    for(int st=0;st<3;st++)v.push_back({rid(3,s.c,0,st),cch});
    if(s.c!=d.c){v.push_back({rid(4,d.c,0,0),(uint16_t)F.package_words_per_output});for(int st=0;st<3;st++)v.push_back({rid(5,d.c,0,st),cch});}
    v.push_back({rid(6,d.c,d.cl,0),ccl});v.push_back({rid(6,d.c,d.cl,1),ccl});return v;
}
static inline uint64_t key_rc(uint32_t r,uint32_t cyc){return ((uint64_t)r<<24)|cyc;}
static inline uint64_t key_tc(int tile,int cyc){return ((uint64_t)tile<<32)|(uint32_t)cyc;}
static inline uint64_t key_bank(int tile,int slot,int bank,int cyc){return ((uint64_t)tile<<40)|((uint64_t)slot<<39)|((uint64_t)bank<<32)|(uint32_t)cyc;}
static inline int bank_color(int node,int tile){ return (int)(((uint64_t)(node/F.tiles())*17u + (uint32_t)tile*5u) & 31u); }

struct Result{
    string name; int n=0,makespan=0; double util=0, eml_t=0, comp_s=0, nodes_s=0, wait_edge=0; double imbalance=0;
    array<uint64_t,4> edge_level{};
};

static Result compile_graph(const string& name, vector<Parents>& P){
    auto t0=chrono::steady_clock::now(); int n=P.size(),T=F.tiles();
    vector<int> pl(n),load(T,0); double target=max(1.0,(double)n/T); int rr=0;
    for(int v=0;v<n;v++){
        int pa=P[v].a,pb=P[v].b,tile;
        if(pa<0){tile=rr++%T;}
        else{
            array<int,10> cand{};int m=0; auto add=[&](int x){for(int i=0;i<m;i++)if(cand[i]==x)return; cand[m++]=x;};
            for(int p: {pa,pb}) if(p>=0){int pt=pl[p];add(pt);auto x=loc(pt);int base=x.c*384+x.cl*16;add(base+((x.t+1)&15));add(base+((x.t+5)&15));add(base+((x.t+9)&15));}
            add(rr++%T); double bs=1e100;int best=cand[0];
            for(int i=0;i<m;i++){int q=cand[i];double sc=0;if(pa>=0)sc+=hcost(pl[pa],q);if(pb>=0)sc+=hcost(pl[pb],q);double rat=load[q]/target;sc+=2.0*rat+30.0*max(0.0,rat-1.10);if(sc<bs){bs=sc;best=q;}} tile=best;
        }
        pl[v]=tile;load[tile]++;
    }
    vector<int> issue(n,0);
    unordered_map<uint64_t,uint16_t> route; route.reserve((size_t)n*3);
    unordered_map<uint64_t,uint16_t> ingress; ingress.reserve((size_t)n/2);
    unordered_map<uint64_t,uint8_t> bank; bank.reserve((size_t)n);
    unordered_map<uint64_t,uint8_t> tile_issue; tile_issue.reserve((size_t)n/4);
    uint64_t waits=0,edges=0; array<uint64_t,4> lev{}; int maxc=0;
    for(int v=0;v<n;v++){
        int dst=pl[v]; int earliest=0; int slot=0;
        for(int p: {P[v].a,P[v].b}){
            if(p<0){slot++;continue;} int src=pl[p]; auto A=loc(src),B=loc(dst);int lidx=src==dst?0:(A.c==B.c&&A.cl==B.cl?1:(A.c==B.c?2:3));lev[lidx]++;edges++;
            auto path=path_for(src,dst); int start=issue[p]+1,wait=0,arr=0;
            for(;;wait++){
                bool ok=true; for(size_t j=0;j<path.size();j++){auto &s=path[j];auto k=key_rc(s.id,start+wait+(int)j);auto it=route.find(k);if(it!=route.end()&&it->second>=s.cap){ok=false;break;}}
                arr=start+wait+(int)path.size();
                if(src!=dst){auto ik=key_tc(dst,arr);auto ii=ingress.find(ik);if(ok&&ii!=ingress.end()&&ii->second>=F.ingress_ports)ok=false;}
                auto bk=key_bank(dst,slot,bank_color(v,dst),arr);if(ok&&bank.find(bk)!=bank.end())ok=false;
                if(ok)break;
            }
            for(size_t j=0;j<path.size();j++)route[key_rc(path[j].id,start+wait+(int)j)]++;
            if(src!=dst) ingress[key_tc(dst,arr)]++;bank[key_bank(dst,slot,bank_color(v,dst),arr)]=1;waits+=wait;
            earliest=max(earliest,arr+1);slot++;
        }
        int cyc=earliest; for(;;cyc++){auto k=key_tc(dst,cyc);auto it=tile_issue.find(k);if(it==tile_issue.end()||it->second<F.lanes_per_tile){tile_issue[k]++;break;}}
        issue[v]=cyc;maxc=max(maxc,cyc);
    }
    auto t1=chrono::steady_clock::now(); double sec=chrono::duration<double>(t1-t0).count();
    int makespan=maxc+1; double util=(double)n/(makespan*F.lanes()); double avg=(double)n/T;int mx=*max_element(load.begin(),load.end());
    Result r; r.name=name;r.n=n;r.makespan=makespan;r.util=util;r.eml_t=util*F.lanes()*F.hz/1e12;r.comp_s=sec;r.nodes_s=n/sec;r.wait_edge=edges?(double)waits/edges:0;r.imbalance=mx/avg;r.edge_level=lev;return r;
}

int main(int argc,char**argv){
    int n=1966080; string profile="target_80_15_3_2"; string topology="express";
    for(int i=1;i<argc;i++){
        string a=argv[i]; auto need=[&](const char*name){if(i+1>=argc){cerr<<"missing value for "<<name<<"\n";exit(2);}return string(argv[++i]);};
        if(a=="--nodes") n=stoi(need("--nodes"));
        else if(a=="--roots") G_ROOTS=stoi(need("--roots"));
        else if(a=="--profile") profile=need("--profile");
        else if(a=="--topology") topology=need("--topology");
        else if(a=="--planes") F.radix_planes=stoi(need("--planes"));
        else if(a=="--package-words") F.package_words_per_output=stoi(need("--package-words"));
        else {cerr<<"unknown arg "<<a<<"\n";return 2;}
    }
    G_EXPRESS=(topology=="express");
    if(topology!="express"&&topology!="radix"){cerr<<"topology must be express|radix\n";return 2;}
    if(G_ROOTS<=0||G_ROOTS>n||G_ROOTS%F.tiles()!=0){cerr<<"roots must be >0, <=nodes and divisible by 1536\n";return 2;}
    vector<string> names;
    if(profile=="all") names={"all_local","target_80_15_3_2","cluster_heavy","global_shuffle","reduction_tree"};
    else names={profile};
    cout<<"XPU V2.4 GLOBAL WAVEFRONT LOCAL C++ BENCH\n";
    cout<<"nodes/case="<<n<<" roots="<<G_ROOTS<<" lanes="<<F.lanes()<<" topology="<<topology<<" planes="<<F.radix_planes<<" package_words/out/cycle="<<F.package_words_per_output<<" raw="<<fixed<<setprecision(4)<<F.lanes()*F.hz/1e12<<" T EML/s\n";
    for(auto &name:names){auto P=gen_locality_profile(n,name);auto r=compile_graph(name,P);uint64_t e=r.edge_level[0]+r.edge_level[1]+r.edge_level[2]+r.edge_level[3];auto pct=[&](int i){return e?100.0*r.edge_level[i]/e:0.0;};
        cout<<left<<setw(20)<<name<<right<<" util="<<setw(6)<<setprecision(2)<<100*r.util<<"% cycles="<<setw(6)<<r.makespan<<" model="<<setw(7)<<setprecision(3)<<r.eml_t<<" T/s compile="<<setw(7)<<setprecision(3)<<r.nodes_s/1e6<<" Mnode/s wait="<<setw(7)<<setprecision(3)<<r.wait_edge<<" cut="<<setprecision(1)<<pct(0)<<"/"<<pct(1)<<"/"<<pct(2)<<"/"<<pct(3)<<"%\n";
    }
    cout<<"XPU_V24_GLOBAL_COMPILER_PASS\n"; return 0;
}
