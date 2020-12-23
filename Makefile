.PHONY: compile rel cover test typecheck doc ci

REBAR=./rebar3
SHORTSHA=`git rev-parse --short HEAD`
PKG_NAME_VER=${SHORTSHA}

OS_NAME=$(shell uname -s)

grpc_services_directory=src/grpc/autogen

ifeq (${OS_NAME},FreeBSD)
make="gmake"
else
MAKE="make"
endif

compile: | $(grpc_services_directory)
	$(REBAR) format && $(REBAR) compile

shell:
	$(REBAR) shell

grpc:
	REBAR_CONFIG="config/grpc_server_gen.config" $(REBAR) grpc gen;\
	REBAR_CONFIG="config/grpc_client_gen.config" $(REBAR) grpc gen

clean:
	rm -rf $(grpc_services_directory)
	$(REBAR) clean

cover:
	$(REBAR) cover

test: | $(grpc_services_directory)
	$(REBAR) as test do ct --suite test/grpc_SUITE

ci: | $(grpc_services_directory)
	$(REBAR) do dialyzer,xref && $(REBAR) as test do eunit,ct,cover
	$(REBAR) covertool generate
	codecov --required -f _build/test/covertool/sibyl.covertool.xml

typecheck:
	$(REBAR) dialyzer

doc:
	$(REBAR) edoc

$(grpc_services_directory):
	@echo "grpc service directory $(directory) does not exist, will generate services"
	$(REBAR) get-deps;$(MAKE) grpc