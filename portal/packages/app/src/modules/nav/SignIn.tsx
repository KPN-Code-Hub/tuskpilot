import { SignInPageBlueprint } from '@backstage/plugin-app-react';
import { TuskpilotLogo } from './TuskpilotLogo';

/** The default guest sign-in, centred and branded. */
export const TuskpilotSignInPage = SignInPageBlueprint.make({
  params: {
    loader: async () => {
      const { SignInPage } = await import('@backstage/core-components');
      return props => (
        <SignInPage
          {...props}
          providers={['guest']}
          align="center"
          titleComponent={
            <span
              style={{ display: 'inline-flex', alignItems: 'center', gap: 16 }}
            >
              <TuskpilotLogo height={34} />
              <span style={{ fontSize: 22, fontWeight: 500, color: '#e9ebf0' }}>
                AI optimized Postgres
              </span>
            </span>
          }
        />
      );
    },
  },
});
