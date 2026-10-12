function tests=test_translation_priors
 tests=functiontests(localfunctions);
end
function setupOnce(tc)
 root=fileparts(fileparts(mfilename('fullpath')));
 tc.applyFixture(matlab.unittest.fixtures.PathFixture(root));
 tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(root,'diagnostics')));
end
function [tr,X,O,cam,cfg]=fixture()
 cfg=config();tr=traj.create_trajectory(0,36,1);rng(47);
 tr.V=[.001,-.002,.003];tr.k=randn(tr.K,1)*1e-4;tr.m=randn(tr.K,3)*1e-4;
 X=randn(8,3)*.1;cam=struct('focal',[300 300],'principal',[160 120]);
 O=[linspace(0,7,30)',mod((0:29)',8)+1,160*ones(30,1),120*ones(30,1),ones(30,1),zeros(30,1)];
end
function testPriorAndImageJacobian(tc)
 [tr,X,O,cam,cfg]=fixture();prob=adjust.setup_problem(tr,X,O,(1:8+4*tr.K)',[],cam,cfg.adjust);
 J=full(adjust.jacobian(prob,tr,X));numeric=zeros(size(J));h=1e-7;
 for col=1:prob.n_free_motion
  step=zeros(8+4*tr.K,1);step(prob.free_parameters(col))=h;
  numeric(:,col)=(adjust.residuals(prob,traj.increment_trajectory(tr,step),X)-adjust.residuals(prob,traj.increment_trajectory(tr,-step),X))/(2*h);
 end
 verifyLessThan(tc,norm(J-numeric,'fro')/norm(numeric,'fro'),1e-7);
 verifyLessThan(tc,max(vecnorm(J(1:prob.n_img,:)-numeric(1:prob.n_img,:))./max(vecnorm(numeric(1:prob.n_img,:)),1)),1e-7);
end
function testFutureAllocationIsNotAnEndpointConstraint(tc)
 [tr,X,O,cam,cfg]=fixture();prob=adjust.setup_problem(tr,X,O,(1:8+4*tr.K)',[],cam,cfg.adjust);
 before=adjust.prior_residuals(prob,tr,X);tr.m(prob.support_end+1:end,:)=10;
 verifyEqual(tc,adjust.prior_residuals(prob,tr,X),before,'AbsTol',1e-10);
 verifyFalse(tc,any(prob.free_parameters>8+tr.K+3*prob.support_end));
 verifyFalse(tc,any(prob.free_parameters>8+prob.support_end & prob.free_parameters<=8+tr.K));
 verifyTrue(tc,all(vecnorm(full(adjust.jacobian(prob,tr,X)))>0));
 prob=adjust.setup_problem(tr,X,O,8+tr.K+3*tr.K,[],cam,cfg.adjust);
 verifyTrue(tc,prob.empty);
 prob=adjust.setup_problem(tr,X,zeros(0,6),(1:8)',[],cam,cfg.adjust);
 verifyTrue(tc,prob.empty);
end
function testTotalVelocityCannotBypassThePrior(tc)
 [tr,X,O,cam,cfg]=fixture();prob=adjust.setup_problem(tr,X,O,(1:8+4*tr.K)',[],cam,cfg.adjust);
 initial=adjust.prior_residuals(prob,tr,X);dv=[.002,.001,-.001];other=tr;
 other.V=tr.V+dv;other.m=tr.m-((-1:tr.K-2)'*tr.h)*dv;
 verifyEqual(tc,traj.translation(tr,O(:,1)),traj.translation(other,O(:,1)),'AbsTol',1e-12);
 changed=adjust.prior_residuals(prob,other,X);
 velocity_rows=4*(tr.K-2)+tr.K+(1:3*tr.K);
 verifyEqual(tc,changed(velocity_rows),initial(velocity_rows),'AbsTol',1e-10);
 % A slope gauge distinguishes the otherwise identical representations.
 slope_rows=4*(tr.K-2)+4*tr.K+4+(1:3);
 verifyGreaterThan(tc,norm(changed(slope_rows)-initial(slope_rows)),1);
end
function testSplineRecoversCurvedTranslation(tc)
 data=simulate_translation_case([.001,0,.001]);truth=data.truth;
 knot_tau=(-1:truth.K-2)'*truth.h;
 truth.m=(knot_tau.^2-truth.h^2/3)*[.00005,0,-.00003];
 [R,T]=traj.pose(truth,data.O(:,1));uv=geom.project(R,T,data.X(data.ii,:),data.cam);
 O=data.O;O(:,3:4)=uv;estimate=truth;estimate.V(:)=0;estimate.m(:)=0;
 acfg=data.cfg.adjust;acfg.lambda_translation=0;acfg.velocity_weight=0;
 free=traj.select_free_parameters(estimate,true,6,[],true);
 free=free(free>=6 & (free<=8 | free>8+truth.K));
 [estimate,~,~]=adjust.refine(estimate,data.X,O,free,[],30,data.cam,acfg);
 t=(0:.1:5.9)';error=traj.translation(estimate,t)-traj.translation(truth,t);
 verifyLessThan(tc,max(vecnorm(error,2,2)),1e-5);
 T=traj.translation(estimate,[0;3;5.9]);
 verifyGreaterThan(tc,norm(T(2,:)-(T(1,:)+3/5.9*(T(3,:)-T(1,:)))),3e-4);
end
